"""Compute the review fan-out plan for review_fanout_guard.sh (dotfiles-dev#480).

Invoked with NO arguments, from a checkout of the target repo — the same convention
``dispatch_plan.py`` (#433) and its own ``round_dispatch_guard.sh`` caller already rely on.
Prints exactly one JSON object to stdout, the same shape ``dispatch_plan.py`` produces for
issues, keyed on ``pr`` instead of ``issue``::

    {"rung":         {"status": "ok", "runtime": "qwen", "model": "…", "signal": "…"},
     "dispatchable": [{"pr": 520, "head": "e131992…", "checks": {…}}],
     "excluded":     [{"pr": 453, "reason": "…"}]}

**It emits the assignment set and never dispatches.** Determinism here belongs to the
SCHEDULING only — which PRs get a reviewer. Nothing in this file accepts, applies or resolves
a review finding, and nothing downstream should: a deterministic fan-out that auto-applied
findings would industrialise the false positives and be strictly worse than the prose it
replaces (dotfiles-dev#480, "The boundary this must not cross").

"NEEDS A REVIEW?" IS NOT ``reviews | length == 0``
--------------------------------------------------
A push moves the head and invalidates every earlier review, so the question is about the
CURRENT HEAD, never about a count. Measured on this repo 2026-09-26:

* **PR #520** — head ``e1319925``, ``reviews | length == 9``, ``mergeStateStatus: BLOCKED``.
  Every one of those 9 reviews carries ``commit.oid`` of an OLDER head (``d2c181fe``,
  ``55c5dca2``, ``3958727``); none names ``e1319925``. A count-based predicate calls #520
  reviewed while no reviewer has seen the code that would merge, and the repo's own
  published check-run said so in words: "no reviewer has reported on this new head yet".
* **PR #453** — head ``bf46b291`` (``committedDate`` 2026-09-23T22:19:09Z),
  ``reviews | length == 0``, yet two real fallback reviews landed on it, as PR COMMENTS
  carrying ``reviewer_ladder.sh``'s own attribution line, at 14:54:24Z and 21:20:38Z. Both
  predate the head. So #453 is simultaneously a counter-example to BOTH obvious answers: a
  count of submitted reviews says "never reviewed" (it was, twice), and a head-agnostic
  attribution-line match — what ``ladder_already_covered`` does — says "already covered"
  (not for this head, it isn't).

The predicate is therefore **coverage of the current head across BOTH channels**, because
the two rungs publish to different places and neither channel alone sees the other:

1. a submitted review whose ``commit.oid`` equals ``headRefOid`` — the primary rung's
   channel, exact, no timestamp reasoning needed;
2. **or** a comment carrying the ladder's attribution line whose ``createdAt`` is strictly
   after the head commit's ``committedDate`` — the fallback rung's channel, which produces
   no review object at all.

``needs_review`` is the negation of that union. A PR whose head commit is not resolvable at
all is UNKNOWN, never "needs a review" and never "covered" — it is excluded by name.

⚠️ ``ladder_attribution_line`` (reviewer_ladder.sh) carries runtime/model/signal but **no
head SHA**, so channel 2 can only be head-scoped by TIME. That is exact in the direction
that matters — a comment posted before the head existed provably did not review it — and
loose by the few seconds between a push and a comment already in flight. Embedding the head
SHA in the attribution line would make channel 2 as exact as channel 1; that is a change to
``reviewer_ladder.sh``, filed as a follow-up rather than made here.

🔴 THE STEP-4 REVIEW-GATE CHECK WAS EVALUATED AS A PREDICATE AND REJECTED. #480 offers it as
a third candidate ("authoritative for threads"). It is not resolvable by name: measured the
same day, PR #520's head carried **two** ``CheckRun``s both named ``Review threads
answered``, one ``SUCCESS`` and one ``FAILURE`` (the workflow job, and a run POSTed by the
workflow). Resolving a check by name-and-first-match returns whichever one the API happens
to list first — a coin flip that reads as an authoritative verdict. ``check_states`` below
therefore groups the rollup BY NAME and reports a name with disagreeing terminal verdicts as
``ambiguous``, never as pass or fail; the field is informational for the guard's message and
is deliberately not an eligibility input.

⚠️ A rollup entry's ``status`` and ``conclusion`` are different fields and an IN_PROGRESS
``CheckRun`` has an EMPTY ``conclusion`` — so ``conclusion != "SUCCESS"`` reports a check
that is still running as failed. ``check_states`` splits running from failing on ``status``
(``CheckRun``) / ``state`` (``StatusContext``) first, and only then reads ``conclusion``.

Fails CLOSED AS ONE UNIT, never partially: anything that breaks the read itself (``gh``
missing, not authenticated, a malformed response, an open-PR count at the ``--limit`` cap)
raises, printing a traceback to stderr and nothing parseable to stdout — which is exactly
what the guard's shape check reads as UNREADABLE and blocks on. A *recoverable* failure is
different: an unresolvable reviewer rung is surfaced as ``rung.status`` plus a named
exclusion reason on every PR — still a valid, still complete JSON object, never a partial
plan that reads as "only these three qualify".

The rung itself comes from #479's shipped probe (``resolve_fallback_reviewer``,
reviewer_ladder.sh), called once per plan and never re-implemented here.
"""

from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

LIB_DIR = Path(__file__).resolve().parent
REVIEWER_LADDER_SH = LIB_DIR / "reviewer_ladder.sh"

GH_TIMEOUT = 30

# open_prs()'s own `--limit`, and the truncation cap `build_plan` checks its read against:
# same contract dispatch_plan.py's OPEN_PR_LIST_CAP documents (PR #506 review) — a truncated
# read silently drops open PRs, and a PR missing from the plan is indistinguishable from one
# that needed no reviewer.
OPEN_PR_LIST_CAP = 200

PR_FIELDS = (
	"number,headRefOid,mergeStateStatus,isDraft,reviews,comments,commits,statusCheckRollup"
)

# The literal ladder_attribution_line() prefix (reviewer_ladder.sh). Matched per-line and
# anchored, the same shape ladder_already_covered's own `test("^Fallback review — runtime:";
# "m")` uses — never a substring search anywhere in the body, which any quoting commenter
# would satisfy.
LADDER_ATTRIBUTION_RE = re.compile("^Fallback review — runtime:", re.MULTILINE)

# Mirrors step 4b's own rule, and ladder_recently_pushed's default: a push already triggers a
# re-review, so a fan-out ask on top of one spends a rung for nothing.
RECENT_PUSH_SECONDS = int(os.environ.get("REVIEW_FANOUT_RECENT_PUSH_SECONDS", "600"))

# Total budget for the rung probe. resolve_fallback_reviewer makes LIVE model calls (that is
# the whole point of #479 — the cache lists what exists, never what this account may call)
# and can walk several candidates at its own per-probe timeout. A Stop hook is synchronous,
# so the walk gets one overall deadline; exceeding it is `unknown`, never `none`.
RUNG_TIMEOUT = int(os.environ.get("REVIEW_FANOUT_RUNG_TIMEOUT", "45"))

# `conclusion` values that are not a failure. NEUTRAL/SKIPPED are how a conditional job
# reports "did not need to run" — counting either as failing would make almost every PR look
# red.
PASSING_CONCLUSIONS = frozenset({"SUCCESS", "NEUTRAL", "SKIPPED"})
# StatusContext's `state`, the legacy commit-status channel: it has no status/conclusion pair.
PASSING_STATES = frozenset({"SUCCESS"})
RUNNING_STATES = frozenset({"PENDING", "EXPECTED", ""})

_RUNG_SCRIPT = r"""
set -u
command -v jq >/dev/null 2>&1 || exit 3
# shellcheck source=/dev/null
source "$1" || exit 3
if resolve_fallback_reviewer; then
	printf '%s\t%s\t%s\n' "$LADDER_RUNTIME" "$LADDER_MODEL" "$LADDER_SIGNAL"
else
	printf 'none\t\t\n'
fi
"""


def _run(cmd: list[str]) -> str:
	"""Run a command and return its stripped stdout.

	Raises on any non-zero exit or timeout, deliberately: a broken read here must surface as
	this script's own failure (see the module docstring's fail-closed note), never as a
	silently empty answer.
	"""
	result = subprocess.run(  # noqa: S603 - fixed argv lists, no shell, no user input
		cmd, capture_output=True, text=True, timeout=GH_TIMEOUT, check=True
	)
	return result.stdout.strip()


def parse_ts(value: str | None) -> datetime.datetime | None:
	"""Return an aware datetime for a GitHub ISO-8601 timestamp, or None when unreadable.

	None is a real answer here, not an error: every caller treats an unreadable timestamp as
	UNKNOWN and excludes the PR by name rather than guessing a coverage verdict.
	"""
	if not value:
		return None
	try:
		return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
	except ValueError:
		return None


def open_prs() -> list[dict]:
	"""Return every open PR with the fields the predicate and the eligibility rules need.

	One ``gh pr list`` call for the whole plan — ``reviews``, ``comments``, ``commits`` and
	``statusCheckRollup`` are all available on the list endpoint, so a per-PR ``gh pr view``
	fan-out (N calls, the shape that drained both REST and GraphQL buckets in #445) is not
	needed to build this plan.
	"""
	raw = _run(
		[
			"gh",
			"pr",
			"list",
			"--state",
			"open",
			"--limit",
			str(OPEN_PR_LIST_CAP),
			"--json",
			PR_FIELDS,
		]
	)
	return json.loads(raw) if raw else []


def resolve_rung() -> dict:
	"""Return the reviewer rung #479's probe resolves, as ``{"status", "runtime", …}``.

	``status`` is ``ok`` (a rung resolved), ``none`` (the probe ran and no rung is
	assignable — a rung that is absent, unwired or unauthenticated) or ``unknown`` (the probe
	itself could not be run: no ladder on disk, no jq, a crash, or the deadline).

	``none`` and ``unknown`` are kept apart on purpose. ``none`` is a measured answer and
	becomes every PR's named exclusion reason — the legitimate zero case. ``unknown`` is
	blindness, and the guard blocks on it: a gate that reports its own blindness as routine
	silence is this toolchain's own recorded failure mode (#396, #433).

    ``REVIEW_FANOUT_RUNG`` overrides the probe for tests and dry runs — ``unknown``,
    ``none``, or ``runtime|model|signal``. Real tests must never shell out to a live model.
	"""
	override = os.environ.get("REVIEW_FANOUT_RUNG")
	if override is not None:
		if override in ("unknown", "none"):
			return {"status": override, "runtime": "", "model": "", "signal": ""}
		runtime, _, rest = override.partition("|")
		model, _, signal = rest.partition("|")
		return {"status": "ok", "runtime": runtime, "model": model, "signal": signal}

	if not REVIEWER_LADDER_SH.is_file():
		return {"status": "unknown", "runtime": "", "model": "", "signal": ""}
	try:
		proc = subprocess.run(  # noqa: S603, S607 - fixed argv, script is a module constant
			["bash", "-c", _RUNG_SCRIPT, "review_fanout_plan", str(REVIEWER_LADDER_SH)],
			capture_output=True,
			text=True,
			timeout=RUNG_TIMEOUT,
			check=False,
		)
	except (OSError, subprocess.TimeoutExpired):
		return {"status": "unknown", "runtime": "", "model": "", "signal": ""}
	if proc.returncode != 0:
		return {"status": "unknown", "runtime": "", "model": "", "signal": ""}

	fields = proc.stdout.strip("\n").split("\t")
	if len(fields) != 3:
		return {"status": "unknown", "runtime": "", "model": "", "signal": ""}
	runtime, model, signal = fields
	if runtime in ("", "none"):
		return {"status": "none", "runtime": "", "model": "", "signal": ""}
	return {"status": "ok", "runtime": runtime, "model": model, "signal": signal}


def _entry_verdict(entry: dict) -> str:
	"""Return ``pass``/``fail``/``running`` for one ``statusCheckRollup`` entry.

	``status`` and ``conclusion`` are separate fields and a non-COMPLETED ``CheckRun`` has an
	EMPTY ``conclusion`` — so running is decided FIRST, from ``status``. Reading
	``conclusion != "SUCCESS"`` without that split reports every in-flight check as failed.
	``StatusContext`` (the legacy commit-status channel, e.g. this repo's ``CodeRabbit``
	entry) has neither field and carries ``state`` instead.
	"""
	if entry.get("__typename") == "StatusContext" or "state" in entry:
		state = (entry.get("state") or "").upper()
		if state in RUNNING_STATES:
			return "running"
		return "pass" if state in PASSING_STATES else "fail"
	status = (entry.get("status") or "").upper()
	if status != "COMPLETED":
		return "running"
	return "pass" if (entry.get("conclusion") or "").upper() in PASSING_CONCLUSIONS else "fail"


def check_states(rollup: list | None) -> dict:
	"""Summarise a head's checks as ``{"failing", "running", "ambiguous"}``.

	Grouped BY NAME, never resolved by name-and-first-match: a head can carry two check-runs
	with the SAME name and opposite conclusions (measured on #520 — ``Review threads
	answered`` appeared as both SUCCESS and FAILURE, one from the workflow job and one POSTed
	by the workflow). A name whose entries disagree on pass-vs-fail is reported in
	``ambiguous`` and counted in neither total, because there is no answer to give.
	"""
	by_name: dict[str, set[str]] = {}
	for entry in rollup or []:
		name = entry.get("name") or entry.get("context") or ""
		by_name.setdefault(name, set()).add(_entry_verdict(entry))

	failing: list[str] = []
	running: list[str] = []
	ambiguous: list[str] = []
	for name, verdicts in by_name.items():
		if "pass" in verdicts and "fail" in verdicts:
			ambiguous.append(name)
		elif "running" in verdicts:
			running.append(name)
		elif "fail" in verdicts:
			failing.append(name)
	return {
		"failing": sorted(failing),
		"running": sorted(running),
		"ambiguous": sorted(ambiguous),
	}


def head_commit_time(pr: dict) -> datetime.datetime | None:
	"""Return the ``committedDate`` of the commit ``headRefOid`` names, or None.

	Matched by OID rather than taken as ``commits[-1]``: the list's order is not part of the
	contract, and "the last one listed" being the head is the kind of assumption that is true
	until it silently is not.
	"""
	head = pr.get("headRefOid") or ""
	for commit in pr.get("commits") or []:
		if (commit.get("oid") or "") == head:
			return parse_ts(commit.get("committedDate"))
	return None


def reviewed_at_head(pr: dict) -> bool:
	"""True when a submitted review names the current head commit — coverage channel 1."""
	head = pr.get("headRefOid") or ""
	if not head:
		return False
	return any(
		((review.get("commit") or {}).get("oid") or "") == head
		for review in pr.get("reviews") or []
	)


def ladder_covered_at_head(pr: dict, head_time: datetime.datetime) -> bool:
	"""True when a ladder attribution comment postdates the head commit — channel 2.

	Strictly after, so a comment written before the head existed can never count. See the
	module docstring for why this channel is time-scoped rather than SHA-scoped, and for the
	follow-up that would make it exact.
	"""
	for comment in pr.get("comments") or []:
		if not LADDER_ATTRIBUTION_RE.search(comment.get("body") or ""):
			continue
		posted = parse_ts(comment.get("createdAt"))
		if posted is not None and posted > head_time:
			return True
	return False


def exclusion_reason(pr: dict, now: datetime.datetime, rung: dict) -> str | None:
	"""Return why this PR gets no reviewer this round, or None when it is dispatchable.

	Ordered most-specific-first so the reason a reader gets is the one that actually settles
	it. Every branch returns a named reason: there is no path out of this function that
	drops a PR silently, which is the whole difference between this plan and the prose it
	replaces.
	"""
	if rung["status"] == "unknown":
		return (
			"reviewer rung UNKNOWN (the #479 probe could not be run or timed out) — "
			"not the same as no rung; re-run before reporting the board reviewed"
		)
	if rung["status"] == "none":
		return (
			"no reviewer rung is assignable (the #479 probe resolved neither qwen nor "
			"codex — absent, unwired or unauthenticated)"
		)
	if pr.get("isDraft"):
		return "draft — not yet offered for review"
	if (pr.get("mergeStateStatus") or "") == "DIRTY":
		return "merge conflict (mergeStateStatus DIRTY) — a review cannot resolve a conflict"

	head_time = head_commit_time(pr)
	if head_time is None:
		return (
			"head commit UNKNOWN (headRefOid absent from the commit list, or an unreadable "
			"committedDate) — head coverage is undecidable, so no reviewer is assigned"
		)
	if (now - head_time).total_seconds() < RECENT_PUSH_SECONDS:
		return (
			f"head pushed less than {RECENT_PUSH_SECONDS}s ago — a push already triggers a "
			"re-review, so an ask on top of it spends a rung for nothing"
		)
	if reviewed_at_head(pr):
		return "already reviewed at the current head (a submitted review names headRefOid)"
	if ladder_covered_at_head(pr, head_time):
		return (
			"already covered at the current head by a fallback review (a ladder "
			"attribution comment postdates the head commit)"
		)
	return None


def build_plan() -> dict:
	"""Assemble the rung, the dispatchable set and the named exclusions for every open PR."""
	prs = open_prs()
	if len(prs) >= OPEN_PR_LIST_CAP:
		raise RuntimeError(
			f"open PR count ({len(prs)}) is at or past the {OPEN_PR_LIST_CAP}-PR cap this "
			"read shares with its own --limit — a truncated read drops open PRs, and a PR "
			"missing from the plan is indistinguishable from one that needed no reviewer; "
			"refusing to print a plan rather than a possibly incomplete one"
		)

	rung = resolve_rung()
	now = datetime.datetime.now(datetime.timezone.utc)
	dispatchable: list[dict] = []
	excluded: list[dict] = []
	for pr in prs:
		number = pr["number"]
		reason = exclusion_reason(pr, now, rung)
		if reason is not None:
			excluded.append({"pr": number, "reason": reason})
			continue
		dispatchable.append(
			{
				"pr": number,
				"head": pr.get("headRefOid") or "",
				"checks": check_states(pr.get("statusCheckRollup")),
			}
		)

	dispatchable.sort(key=lambda c: c["pr"])
	excluded.sort(key=lambda c: c["pr"])
	return {"rung": rung, "dispatchable": dispatchable, "excluded": excluded}


def main() -> int:
	"""Print the review fan-out plan as one JSON object and return 0."""
	print(json.dumps(build_plan()))
	return 0


if __name__ == "__main__":
	sys.exit(main())
