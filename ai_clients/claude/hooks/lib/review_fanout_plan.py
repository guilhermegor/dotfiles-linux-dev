"""Compute the review fan-out plan for review_fanout_guard.sh (dotfiles-linux-dev#480).

Invoked with NO arguments, from a checkout of the target repo — the same convention
``dispatch_plan.py`` (#433) and its own ``round_dispatch_guard.sh`` caller already rely on.
Prints exactly one JSON object to stdout, the same shape ``dispatch_plan.py`` produces for
issues, keyed on ``pr`` instead of ``issue``::

    {"rung":         {"status": "ok", "runtime": "qwen", "model": "…", "signal": "…"},
     "dispatchable": [{"pr": 520, "head": "e131992…", "checks": {…}, "ladder": "backlog"}],
     "excluded":     [{"pr": 453, "reason": "…"}]}

**It emits the assignment set and never dispatches.** Determinism here belongs to the
SCHEDULING only — which PRs get a reviewer. Nothing in this file accepts, applies or resolves
a review finding, and nothing downstream should: a deterministic fan-out that auto-applied
findings would industrialise the false positives and be strictly worse than the prose it
replaces (dotfiles-linux-dev#480, "The boundary this must not cross").

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
2. **or** a comment carrying the ladder's attribution line whose second line
   (``Reviewed head: <sha>``) names ``headRefOid`` AND whose ``createdAt`` is strictly after
   the head commit's ``committedDate`` — the fallback rung's channel, which produces no
   review object at all.

``needs_review`` is the negation of that union. A PR whose head commit is not resolvable at
all is UNKNOWN, never "needs a review" and never "covered" — it is excluded by name.

⚠️ Channel 2 is head-scoped by SHA *and* by time (dotfiles-linux-dev#564). The time clause alone
is defeated by a backdated head: committer date is whoever-pushes-controlled, so a new head
can look older than an existing marker for a different commit and inherit its coverage. The
SHA clause answers "was it the same commit"; the time clause still catches a marker written
before the head existed. A marker with no ``Reviewed head:`` line (written before #564)
fails closed into "needs a review" — one extra review, never a permanent skip.

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
missing, not authenticated, a malformed response, an open-PR count at the read ceiling, any one
page of the paged board read) raises, printing a traceback to stderr and nothing parseable to stdout — which is exactly
what the guard's shape check reads as UNREADABLE and blocks on. A *recoverable* failure is
different: an unresolvable reviewer rung is surfaced as ``rung.status`` plus a named
exclusion reason on every PR — still a valid, still complete JSON object, never a partial
plan that reads as "only these three qualify".

The rung itself comes from #479's shipped probe (``resolve_fallback_reviewer``,
reviewer_ladder.sh), called once per plan and never re-implemented here.

``commits`` IS NEVER REQUESTED UNBOUNDED (dotfiles-linux-dev#537)
-----------------------------------------------------------
It was, until this planner's very first live run: ``gh pr list --json …,commits,…`` at
``--limit 200`` is rejected UNCONDITIONALLY by GitHub — "requesting up to 1,000,000 possible
nodes which exceeds the maximum limit of 500,000" — because ``commits`` multiplies 200 PRs by
up to 100 commits each by that commit's own ``authors`` connection. No ``--limit`` this
planner could use rescues it (bisected down to the field on 2026-09-27: the full field
list only clears the cap at ``--limit 20``, one tenth of ``OPEN_PR_LIST_CAP``). The guard read
every resulting traceback as ``UNREADABLE`` and blocked every round since #527 merged — the
plan had never once succeeded, on an empty repo or a busy one, because the cap is computed
from the REQUESTED limits, not the actual data volume. (The same cost model is why the whole
board read is now paged -- dotfiles-linux-dev#600, ``open_pr_pages.py``.)

``commits`` fed exactly one value: ``head_commit_time()`` now fetches that one datum from
REST instead — ``repos/{owner}/{repo}/commits/{oid}`` → ``.commit.committer.date`` — a
different surface from the GraphQL query this planner otherwise uses, which is also what kept
working through the 2026-09-26 secondary limit. This is not the ``gh pr view`` fan-out #445
warns about: one small REST read per open PR, not a full PR object, and memoised by oid so a
rerun against the same head never re-fetches it. Still None on an unreadable read — every
caller already treats None as UNKNOWN and excludes the PR by name, and that must not regress
into a guess just because the read moved to a different endpoint.
"""

from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

from open_pr_pages import read_open_prs

LIB_DIR = Path(__file__).resolve().parent
REVIEWER_LADDER_SH = LIB_DIR / "reviewer_ladder.sh"

GH_TIMEOUT = 30

# open_prs()'s own read ceiling, and the truncation cap `build_plan` checks its read against:
# same contract dispatch_plan.py's OPEN_PR_LIST_CAP documents (PR #506 review) — a truncated
# read silently drops open PRs, and a PR missing from the plan is indistinguishable from one
# that needed no reviewer.
OPEN_PR_LIST_CAP = 200

# Every connection is bounded explicitly (open_pr_pages.py, dotfiles-linux-dev#600). `commits` is
# `last:1` and carries only the rollup -- never the unbounded commit list #537 was rejected for.
# `last:` on reviews/comments keeps the NEWEST 100, which is what head coverage reads; their
# `totalCount` is requested so a window that dropped older entries is known, not assumed whole
# (see `truncated_window`).
PR_SELECTION = (
	"number headRefOid baseRefName mergeStateStatus isDraft "
	"reviews(last:100){totalCount nodes{commit{oid}}} "
	"comments(last:100){totalCount nodes{body createdAt author{login}}} "
	"commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{"
	"__typename ... on CheckRun{name status conclusion} "
	"... on StatusContext{context state}}}}}}}"
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

# A dispatchable PR (no review on its CURRENT head) older than this goes to the fallback
# ladder whatever the primary rung's slot reads (dotfiles-linux-dev#616): slot_classify.py read
# FREE for a week on a 50-PR backlog because "the slot is free" and "PRs are getting reviewed"
# are different facts. A default, not a measurement -- move it when there is one.
LADDER_BACKLOG_HOURS = float(os.environ.get("REVIEW_FANOUT_BACKLOG_HOURS", "6"))

# The reviewer's own refusal to review a bot-authored PR -- structural like the file cap
# (#420): waiting never clears it and re-asking never will, so the ladder is the only path in.
# Matched on the reviewer's login AND the phrase; anyone can type the phrase.
# Exact logins, never a substring: GraphQL reports `coderabbitai`, REST `coderabbitai[bot]`, and a
# lookalike account (`coderabbit-fan`) must not be able to fake a refusal (CWE-290).
REVIEWER_LOGINS = frozenset({"coderabbitai", "coderabbitai[bot]"})
BOT_SKIP_PHRASE = "review skipped"
BOT_SKIP_DETAIL = "bot user detected"

# The repo's own review gate, read by name from the rollup (#705) and never re-derived. Green on
# a head no review names means the review was carried forward (blueprintx#698/#699).
REVIEW_GATE_CHECK = os.environ.get("REVIEW_FANOUT_GATE_CHECK", "Review threads answered")

# The repo's own review gate, read by name from the rollup (#705), never re-derived. Green on a
# head no review names means the review was carried forward (blueprintx#698/#699).
REVIEW_GATE_CHECK = os.environ.get("REVIEW_FANOUT_GATE_CHECK", "Review threads answered")

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


def _flatten(node: dict) -> dict:
	"""Reshape one GraphQL PR node into the flat ``gh pr list --json`` shape every reader uses."""
	rollup = [
		context
		for commit in node["commits"]["nodes"]
		for context in (
			((commit["commit"].get("statusCheckRollup") or {}).get("contexts") or {}).get("nodes")
			or []
		)
	]
	return {
		**{
			k: node[k]
			for k in ("number", "headRefOid", "baseRefName", "mergeStateStatus", "isDraft")
		},
		"reviews": node["reviews"]["nodes"],
		"comments": node["comments"]["nodes"],
		"truncated": [
			name
			for name in ("reviews", "comments")
			if (node[name].get("totalCount") or 0) > len(node[name]["nodes"])
		],
		"statusCheckRollup": rollup,
	}


# Everything a failed read can raise: gh's own failure, or a response that is not the shape asked for.
_READ_ERRORS = (
	subprocess.CalledProcessError,
	subprocess.TimeoutExpired,
	RuntimeError,
	ValueError,
	KeyError,
	TypeError,
)

# REST's page size, and the point at which a REST window is assumed to have dropped entries.
REST_PAGE = 100


def _rest(path: str) -> list | dict:
	"""Return the parsed JSON of one ``gh api <path>`` read (``{owner}``/``{repo}`` filled by gh)."""
	return json.loads(_run(["gh", "api", f"repos/{{owner}}/{{repo}}/{path}"]))


def _rest_window(nodes: list) -> dict:
	"""Shape a REST list as a GraphQL connection; a full page reports one more than it holds.

	REST has no ``totalCount``, so a page that came back full cannot be told from a window that
	dropped older entries -- and ``_flatten`` then marks it truncated, which fails closed into
	"head coverage undecidable" rather than into a guessed "no review".
	"""
	extra = 1 if len(nodes) >= REST_PAGE else 0
	return {"totalCount": len(nodes) + extra, "nodes": nodes}


def _rest_node(pr: dict) -> dict:
	"""Adapt one REST open PR into the GraphQL node shape ``_flatten`` reads (issue #689)."""
	number, head = pr["number"], pr["head"]["sha"]
	detail = _rest(f"pulls/{number}")
	reviews = _rest(f"pulls/{number}/reviews?per_page={REST_PAGE}")
	comments = _rest(f"issues/{number}/comments?per_page={REST_PAGE}")
	runs = _rest(f"commits/{head}/check-runs?per_page={REST_PAGE}")["check_runs"]
	# ponytail: legacy commit statuses (StatusContext) are not read; checks are informational.
	contexts = [
		{
			"__typename": "CheckRun",
			"name": run["name"],
			"status": (run.get("status") or "").upper(),
			"conclusion": (run.get("conclusion") or "").upper(),
		}
		for run in runs
	]
	return {
		"number": number,
		"headRefOid": head,
		"baseRefName": pr["base"]["ref"],
		"mergeStateStatus": (detail.get("mergeable_state") or "").upper(),
		"isDraft": bool(pr.get("draft")),
		"reviews": _rest_window([{"commit": {"oid": r.get("commit_id")}} for r in reviews]),
		"comments": _rest_window(
			[
				{
					"body": c.get("body"),
					"createdAt": c.get("created_at"),
					"author": {"login": (c.get("user") or {}).get("login")},
				}
				for c in comments
			]
		),
		"commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {"nodes": contexts}}}}]},
	}


def _open_pr_nodes_rest() -> list[dict]:
	"""Return every open PR as a GraphQL-shaped node, read over REST (at most the shared cap).

	The fallback when GraphQL is refused by the secondary rate limit while REST still answers
	(dotfiles-linux-dev#689). One list read plus four small reads per PR, serial like the
	GraphQL pages; any failure raises and discards the PRs read so far.
	"""
	prs: list[dict] = []
	page = 1
	while len(prs) < OPEN_PR_LIST_CAP:
		batch = _rest(f"pulls?state=open&per_page={REST_PAGE}&page={page}")
		if not isinstance(batch, list):
			raise RuntimeError("open-PR REST page is not a list")
		prs.extend(batch)
		if len(batch) < REST_PAGE:
			break
		page += 1
	return [_rest_node(pr) for pr in prs]


def open_prs() -> list[dict]:
	"""Return every open PR with the fields the predicate and the eligibility rules need.

	Paged through ``open_pr_pages.read_open_prs`` -- one 200-PR ``gh pr list`` request 502s
	above ~20 PRs (dotfiles-linux-dev#600) -- and still one read for the whole plan: ``reviews``,
	``comments`` and the rollup all arrive on the PR node, so a per-PR ``gh pr view`` fan-out
	(N calls, the shape that drained both REST and GraphQL buckets in #445) is not needed. A
	failing page raises and discards the pages before it. ``commits`` is requested only as
	``last:1`` for the rollup -- see the module docstring's dotfiles-linux-dev#537 section;
	``head_commit_time()`` fetches the head's own commit date from REST instead.

	When the GraphQL read fails (the secondary rate limit refuses it while ``gh api rate_limit``
	still reports quota) the same board is read over REST instead (dotfiles-linux-dev#689). If
	REST fails too, the GraphQL error is the one raised: the board is UNREADABLE, never empty.
	"""
	# _flatten runs inside each guard: a malformed nested field must reach the fallback too.
	try:
		return [_flatten(n) for n in read_open_prs(PR_SELECTION, _run, OPEN_PR_LIST_CAP)]
	except _READ_ERRORS as graphql_error:
		try:
			return [_flatten(n) for n in _open_pr_nodes_rest()]
		except _READ_ERRORS:
			raise graphql_error from None


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


# oid -> resolved committedDate (or None), across every PR in one process's plan. A rerun
# against the same head never re-fetches it; the cost of the extra REST round trip this
# dotfiles-linux-dev#537 fix introduces is paid at most once per distinct oid, not once per PR.
_HEAD_COMMIT_TIME_CACHE: dict[str, datetime.datetime | None] = {}


def head_commit_time(pr: dict) -> datetime.datetime | None:
	"""Return the ``committedDate`` of the commit ``headRefOid`` names, or None.

	Fetched from REST (``repos/{owner}/{repo}/commits/{oid}``) rather than read off the
	``gh pr list`` response — see the module docstring's dotfiles-linux-dev#537 section for why
	``commits`` cannot be requested unbounded at all. ``{owner}``/``{repo}`` are resolved by
	``gh`` itself from the working directory, the same way ``gh pr list`` resolves its repo.

	None on an unreadable read (no ``gh``, no auth, an unknown oid, a timeout) — never guessed.
	Every caller already treats None as UNKNOWN and excludes the PR by name; that contract must
	survive the read moving to a different endpoint.
	"""
	oid = pr.get("headRefOid") or ""
	if not oid:
		return None
	if oid in _HEAD_COMMIT_TIME_CACHE:
		return _HEAD_COMMIT_TIME_CACHE[oid]

	try:
		raw = subprocess.run(  # noqa: S603 - fixed argv, oid comes from gh's own PR list
			[
				"gh",
				"api",
				f"repos/{{owner}}/{{repo}}/commits/{oid}",
				"--jq",
				".commit.committer.date",
			],
			capture_output=True,
			text=True,
			timeout=GH_TIMEOUT,
			check=True,
		).stdout.strip()
	except (OSError, subprocess.SubprocessError):
		raw = ""

	result = parse_ts(raw) if raw else None
	_HEAD_COMMIT_TIME_CACHE[oid] = result
	return result


def reviewed_at_head(pr: dict) -> bool:
	"""True when a submitted review names the current head commit — coverage channel 1."""
	head = pr.get("headRefOid") or ""
	if not head:
		return False
	return any(
		((review.get("commit") or {}).get("oid") or "") == head
		for review in pr.get("reviews") or []
	)


def names_head(body: str, head: str) -> bool:
	"""True when the marker's own SECOND line is ``Reviewed head: <head>``.

	Same test as ``ladder_already_covered`` / the thread gate (dotfiles-linux-dev#564), so the
	three readers of a marker cannot disagree about which commit it reviewed. A marker with
	no second line (written before #564) or an unresolved ``head`` is False — fail closed.
	"""
	lines = body.split("\n")
	return bool(head) and len(lines) > 1 and lines[1] == f"Reviewed head: {head}"


def ladder_covered_at_head(pr: dict, head_time: datetime.datetime) -> bool:
	"""True when a ladder attribution comment reviewed THIS head — channel 2.

	Two independent AND clauses, neither subsuming the other: the marker's own
	``Reviewed head:`` line names ``headRefOid`` (which commit), and it was posted strictly
	after the head commit (a comment written before the head existed provably did not
	review it). A time-only check is defeated by a backdated head whose committer date
	predates an existing marker for a different commit (dotfiles-linux-dev#564).
	"""
	head = pr.get("headRefOid") or ""
	for comment in pr.get("comments") or []:
		body = comment.get("body") or ""
		if not LADDER_ATTRIBUTION_RE.search(body) or not names_head(body, head):
			continue
		posted = parse_ts(comment.get("createdAt"))
		if posted is not None and posted > head_time:
			return True
	return False


def truncated_window(pr: dict) -> str | None:
	"""Return the names of the connections whose 100-node window dropped older entries.

	A positive coverage hit inside the window is valid however much was dropped, but "no
	coverage in view" is only a verdict when the window held everything -- otherwise the
	review or attribution comment covering this head may be in the part that was not read,
	and offering a reviewer would be a duplicate assignment on a guess.
	"""
	return " and ".join(pr.get("truncated") or []) or None


def bot_skipped(pr: dict) -> bool:
	"""True when the reviewer posted its "Review skipped -- Bot user detected" notice.

	Any head: the refusal is about who authored the PR, not about a commit, so a push does not
	clear it. Author-checked -- the phrase alone is typeable by any commenter.
	"""
	for comment in pr.get("comments") or []:
		login = ((comment.get("author") or {}).get("login") or "").lower()
		body = (comment.get("body") or "").lower()
		if login in REVIEWER_LOGINS and BOT_SKIP_PHRASE in body and BOT_SKIP_DETAIL in body:
			return True
	return False


def ladder_reason(pr: dict, now: datetime.datetime) -> str | None:
	"""Return why a DISPATCHABLE PR belongs on the fallback ladder regardless of slot state.

	``bot-skipped`` (structural refusal) or ``backlog`` (no review on the current head for
	longer than ``LADDER_BACKLOG_HOURS``); None otherwise. Only called for PRs that already
	passed ``exclusion_reason``, so DIRTY, draft and just-pushed heads never get here.
	"""
	if bot_skipped(pr):
		return "bot-skipped"
	head_time = head_commit_time(pr)
	if head_time is not None and (now - head_time).total_seconds() > LADDER_BACKLOG_HOURS * 3600:
		return "backlog"
	return None


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
	dropped = truncated_window(pr)
	if dropped:
		return (
			f"{dropped} truncated (more than 100 entries; the read window dropped older "
			"ones) — head coverage is undecidable, so no reviewer is assigned"
		)
	return None


def _gh_text(args: list[str]) -> str:
	"""Return ``gh api <args>`` stdout, or "" on ANY failure (no auth, 404, timeout).

	Unlike ``_run`` this never raises: it feeds ``merge_is_serial``, whose unreadable answer
	must fall back to the parallel plan this module always produced, not fail the whole read.
	"""
	try:
		return _run(["gh", "api", *args])
	except (OSError, subprocess.SubprocessError):
		return ""


_SERIAL_CACHE: dict[str, bool] = {}


def merge_is_serial(base: str) -> bool:
	"""True when merging INTO ``base`` is inherently serial, so a reviewer per PR is wasted (#646).

	Under a strict required-status-checks policy every merge puts every other PR behind and
	updating a branch voids its review: reviews done in parallel are thrown away (blueprintx,
	2026-10-04/05: 13 agents, 3 session limits and a weekly limit for 2 merges). Strictness is
	per BASE branch -- a PR targeting ``release/x`` is governed by that branch's rules, not the
	default's -- read from the effective RULESETS (``rules/branches``) AND classic branch
	protection (classic said ``strict: false`` on the repo that motivated this). One read pair
	per distinct base, memoised. ``REVIEW_FANOUT_SERIAL=1|0`` declares it for every base
	instead (a merge queue the API cannot show). Unreadable => False: the pre-#646 parallel
	plan, never a guess at serial.
	"""
	declared = os.environ.get("REVIEW_FANOUT_SERIAL", "")
	if declared in ("0", "1"):
		return declared == "1"
	if not base:
		return False
	if base in _SERIAL_CACHE:
		return _SERIAL_CACHE[base]
	ruleset = _gh_text(
		[
			f"repos/{{owner}}/{{repo}}/rules/branches/{base}",
			"--jq",
			'[.[] | select(.type == "required_status_checks")'
			" | .parameters.strict_required_status_checks_policy] | any",
		]
	)
	strict = ruleset == "true"
	if not strict:
		strict = (
			_gh_text(
				[
					f"repos/{{owner}}/{{repo}}/branches/{base}/protection/required_status_checks",
					"--jq",
					".strict",
				]
			)
			== "true"
		)
	_SERIAL_CACHE[base] = strict
	return strict


def drain_serially(dispatchable: list[dict], excluded: list[dict]) -> None:
	"""Per base branch, keep only the queue head (lowest PR number); exclude the rest, by name.

	In place. Only PRs whose ``base`` is serial are touched; PRs on a non-serial base stay
	parallel. Each drained PR gets a named reason -- the plan still judges every PR, it just
	refuses to buy a review that the next merge into that base will void. The legitimate state
	is "the next PR in the queue has a review in flight", which ``review_fanout_guard.sh``
	already honours.
	"""
	heads: dict[str, int] = {}
	kept: list[dict] = []
	for item in sorted(dispatchable, key=lambda c: c["pr"]):
		base = item.get("base") or ""
		if not merge_is_serial(base):
			kept.append(item)
			continue
		if base not in heads:
			heads[base] = item["pr"]
			kept.append(item)
			continue
		excluded.append(
			{
				"pr": item["pr"],
				"reason": (
					f"serial drain: merges into {base} are strict-serial, so a review of "
					f"this head is voided by the merge ahead of it -- #{heads[base]} is "
					"next in the queue and gets the reviewer"
				),
			}
		)
	dispatchable[:] = kept


def _clean_checks(pr: dict) -> list:
	"""Return the PR's rollup when no check is failing, running or ambiguous, else ``[]``.

	Reuses ``check_states`` (grouped by name, never first-match). An empty rollup is "no
	evidence of green", so it comes back as ``[]`` too.
	"""
	rollup = pr.get("statusCheckRollup") or []
	states = check_states(rollup)
	return [] if states["failing"] or states["running"] or states["ambiguous"] else rollup


def merge_ready(pr: dict) -> bool:
	"""True when a serial-drain PR is gate-green on its current head and only BEHIND (#705).

	One source of truth: the repo's own review gate (``REVIEW_GATE_CHECK``), read from the
	head-scoped rollup, must be present and passing, every other check clean (``_clean_checks``),
	and ``mergeStateStatus`` exactly ``BEHIND``. A gate that carries reviews forward
	(blueprintx#698/#699) is green on an updated head; one that does not is red and the PR
	stays review work. Comment bodies and review objects are deliberately NOT read here: neither
	is author-checked (anyone can quote an attribution line), while a check on the head is
	written only by the repo's own CI. Fail closed -- a missing gate, empty rollup, draft or
	any other merge state is "not ready": a wrong "ready" merges unreviewed code.
	"""
	if pr.get("isDraft") or (pr.get("mergeStateStatus") or "") != "BEHIND":
		return False
	rollup = _clean_checks(pr)
	return any(
		(entry.get("name") or entry.get("context") or "") == REVIEW_GATE_CHECK for entry in rollup
	)


def build_plan() -> dict:
	"""Assemble the rung, the dispatchable set and the named exclusions for every open PR."""
	prs = open_prs()
	if len(prs) >= OPEN_PR_LIST_CAP:
		raise RuntimeError(
			f"open PR count ({len(prs)}) is at or past the {OPEN_PR_LIST_CAP}-PR cap this "
			"read shares with its own ceiling — a truncated read drops open PRs, and a PR "
			"missing from the plan is indistinguishable from one that needed no reviewer; "
			"refusing to print a plan rather than a possibly incomplete one"
		)

	rung = resolve_rung()
	now = datetime.datetime.now(datetime.timezone.utc)
	dispatchable: list[dict] = []
	excluded: list[dict] = []
	ready: list[dict] = []
	for pr in prs:
		number = pr["number"]
		# Before the rung check on purpose: an update-branch needs no reviewer (#705).
		base = pr.get("baseRefName") or ""
		if merge_is_serial(base) and merge_ready(pr):
			ready.append({"pr": number, "head": pr.get("headRefOid") or "", "base": base})
			continue
		reason = exclusion_reason(pr, now, rung)
		if reason is not None:
			excluded.append({"pr": number, "reason": reason})
			continue
		dispatchable.append(
			{
				"pr": number,
				"head": pr.get("headRefOid") or "",
				"base": pr.get("baseRefName") or "",
				"checks": check_states(pr.get("statusCheckRollup")),
				"ladder": ladder_reason(pr, now),
			}
		)

	drain_serially(dispatchable, excluded)
	serial = any(merge_is_serial(c["base"]) for c in dispatchable)
	dispatchable.sort(key=lambda c: c["pr"])
	excluded.sort(key=lambda c: c["pr"])
	ready.sort(key=lambda c: c["pr"])
	return {
		"rung": rung,
		"serial": serial,
		"merge_ready": ready,
		"dispatchable": dispatchable,
		"excluded": excluded,
	}


def main() -> int:
	"""Print the review fan-out plan as one JSON object and return 0.

	A `gh` failure (a real API refusal, including a secondary GraphQL rate limit -- measured
	live, dotfiles-linux-dev#559 follow-up) or a timeout must read as an actionable UNKNOWN, never
	an uncaught traceback. `review_fanout_guard.sh` already fails closed on this either way
	(empty/unparseable stdout plus a non-zero exit is its own UNREADABLE contract,
	dotfiles-linux-dev#480's `block_unreadable`) -- this is about what an agent running the planner
	DIRECTLY during s:dev-loop step 4b sees on its own screen: one line naming the failure,
	not a raw Python stack trace with no bearing on what to do next.
	"""
	try:
		print(json.dumps(build_plan()))
	except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
		print(f"review_fanout_plan: could not read the board -- {exc}", file=sys.stderr)
		return 1
	return 0


if __name__ == "__main__":
	sys.exit(main())
