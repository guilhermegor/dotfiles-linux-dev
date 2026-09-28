"""Compute the non-colliding dispatch set for round_dispatch_guard.sh (dotfiles-dev#433).

Invoked with NO arguments, from the current working directory — a checkout of the target
repo, the same convention round_dispatch_guard.sh's own ``python3 "$PLANNER"`` call relies
on (it never ``cd``s anywhere first). Prints exactly one JSON object to stdout::

    {"dispatchable": [{"issue": 433, "surface": ["a/b.py"]}],
     "excluded":     [{"issue": 426, "reason": "..."}]}

Collision is agent-vs-agent, never agent-vs-open-PR (dotfiles-dev#433; review findings on PR
#476). The held set fed to ``free_classify_files`` (``lib/free_surface.sh``, #340) is built by
``gate_live_agent_surface`` (same file, dotfiles-dev#572) — called via a subprocess, the same way
``run_gate()`` below shells out to ``gate_free_surface`` — never from ``gate_free_surface``'s own
``FREE_HELD_PATHS``, which unions every open PR's files regardless of whether an agent is still
live on it (a frozen/idle open PR would otherwise suppress dispatch of an unrelated candidate).
Before #572 this script re-walked ``git worktree list`` itself, a second, independently-drifting
copy of the same "which branches are live agents" notion ``hooks/lib/worktree_fanout.sh`` and
``free_surface.sh`` both already owned — and one that never gained #551's forge-confirmed
dead-worktree exclusion, so a merged/closed PR's worktree kept suppressing dispatch here long
after ``free_surface.sh`` learned better. ``gate_free_surface`` is still called for its OTHER
answer: the claimed-issue check (``FREE_UNCLAIMED_ISSUES``) is deliberately
agent-vs-{open,merged}-PR, a different question ("is this issue already being delivered") that
this script leaves untouched. Collapsing ``would-need-a-held-file`` into ``held`` was the specific
bug that hid 97% of a free directory behind a directory-level summary (#340); the mapping below
keeps all three classify states apart on purpose.

An issue's file surface is declared as a fenced ```surface block in its body — the
convention dotfiles-dev#426 formalises with an issue-template requirement; here it is
read, not enforced. An issue with no such block, or an empty one, is reported UNDECLARED,
never "collides with nothing": it is excluded with its own named reason (``UNDECLARED_REASON``,
which leads with the token so a consumer can tell it apart by prefix, not by prose), same as one
whose surface is held.

A glob token in a declared surface is matched against the local checkout tree AND the
live-agent held-paths set (dotfiles-dev#433 finding 3): a live agent's own branch can hold a
file matching the token that never reaches this checkout, and would otherwise read as free.

Because each issue is classified independently, two issues can both come back individually
free while declaring an overlapping path (dotfiles-dev#433 finding 4). ``select_disjoint`` runs
a second, deterministic GREEDY pass — smallest surface first, ties by issue number — reserving
each selected candidate's paths before the next is considered. This is not an optimal
maximum-cardinality solver; #433 explicitly does not require one.

A PR that NAMES an issue (``#N`` in its title or body) without GitHub counting it in
``closingIssuesReferences`` is a third signal, distinct from both "claimed" and "held"
above (dotfiles-dev#413): ``closingIssuesReferences`` only answers "will merging this PR
close issue N", never "does this PR's own text talk about issue N at all" — a missing
``Closes`` line or a deliberate stacked follow-up both look identical to the unclaimed
check, and either way dispatching N risks a duplicate PR against real, in-review work.
Measured on #361/PR#514: ``closingIssuesReferences`` was empty while the PR body named
#361 five times, and the free-surface gate reported #361 as free. ``mentioned_without_
closing`` catches this with its own ``gh pr list`` read (title+body text, never a branch
name) and excludes the issue with the referencing PR named, rather than silently
offering it as a candidate.

Fails LOUD, not closed-and-quiet, on anything that breaks the read itself (``gh`` missing, not
authenticated, a malformed response, or an open-issue count at/above the 500-issue cap
``gate_free_surface``'s own claimed-issue read shares — dotfiles-dev#433 finding 2, LATENT on
this repo's ~33 open issues): an uncaught exception prints a traceback to stderr and nothing
parseable to stdout, which is exactly what round_dispatch_guard.sh's own shape check reads as
UNREADABLE and blocks on. A *recoverable* gate failure (a rate limit, a bad compare, or the
live-agent worktree walk itself failing) is different: it is surfaced as a named UNKNOWN
exclusion reason on every open issue — still a valid, still fail-closed JSON object.

A blocked issue is excluded too (dotfiles-dev#560): a `state:blocked` label or an open native
`issues/<n>/dependencies/blocked_by` entry reports "dispatchable" a candidate no agent's PR could
ever land. Blocked state is read in that order — native relation first (authoritative; it is
what GitHub itself resolves on close), the label second — and reported as its own reason,
distinct from ``UNDECLARED``: an issue can be blocked with or without a declared surface, and
collapsing the two hides which is true. The native read reuses ``roadmap_unblock.sh``'s own
``_ru_native_blockers`` (sourced, never re-derived) so a fix to that function's pagination or
parsing reaches this planner automatically instead of drifting from it. A board-only
``Status = Blocked`` (no label, no native dependency) is deliberately NOT a third source here —
that mismatch is `roadmap_unblock.sh`'s own reconciliation gap to close, not a signal this
planner re-derives. A native-blocker read failure is UNKNOWN and excluded, never "not blocked".
"""

from __future__ import annotations

import fnmatch
import json
import re
import subprocess
import sys
from pathlib import Path

LIB_DIR = Path(__file__).resolve().parent
FREE_SURFACE_SH = LIB_DIR / "free_surface.sh"
ROADMAP_UNBLOCK_SH = LIB_DIR / "roadmap_unblock.sh"
GH_TIMEOUT = 20
GATE_TIMEOUT = 25
# One `_ru_native_blockers` call per open issue, sequential inside a single subprocess (same
# reasoning as GATE_TIMEOUT for the free-surface gate) — generous because a 500-issue repo would
# otherwise need this to scale, but LATENT at this repo's ~33 open issues like the other caps.
BLOCKED_TIMEOUT = 120

# The label this repo's board triad (dotfiles-dev#369/#528) uses for a blocked issue —
# `_ru_unblock` in roadmap_unblock.sh adds/removes the very same string.
BLOCKED_LABEL = "state:blocked"

# gate_free_surface's own `gh issue list --state open --limit 500` cap (free_surface.sh) — not
# editable from here (dotfiles-dev#433 finding 2, see module docstring).
FREE_SURFACE_ISSUE_CAP = 500

# open_prs()'s own `--limit`, and the truncation-detection cap `build_plan` checks its read
# against (PR #506 review): a truncated read can miss an open PR that mentions a later issue,
# reading that issue as unmentioned rather than held — the same failure shape #433 finding 2
# names for the issue read above, so it gets the same fix (fail loud at the cap, never silently
# treat a possibly-truncated list as complete).
OPEN_PR_LIST_CAP = 200

SURFACE_BLOCK_RE = re.compile(r"```surface\s*\n(.*?)```", re.DOTALL)
GLOB_CHARS = ("*", "?", "[")

# The one place an issue's declared-surface convention is named (dotfiles-dev#405 scope 2).
# Today it is the fenced ```surface block above (dotfiles-dev#426). blueprintx#314 will move it
# to a scope LABEL; that format does NOT exist yet and is deliberately not invented here.
# When #314 lands, the label prefix is set below and ``declared_surface`` learns to read it —
# one edit, in one file, because nothing else re-states the convention.
SURFACE_LABEL_PREFIX = ""

# An issue with no declared surface is REPORTED, never assumed free — it is neither dispatchable
# nor quietly dropped. The token leads the reason so a consumer can tell this exclusion apart
# from a real collision by prefix rather than by prose: dispatch_free_surface_guard.sh greps for
# it (and keeps its own copy in lib/dispatch_claims.sh's DISPATCH_UNDECLARED_TOKEN, the shell
# side of this same one-word contract).
UNDECLARED_TOKEN = "UNDECLARED"
UNDECLARED_REASON = (
	f"{UNDECLARED_TOKEN}: no declared file surface (no ```surface block in the issue body) — "
	"declare the surface and this issue becomes dispatchable; it is never assumed free"
)

# Classifies every request against a caller-supplied held-paths set (the live-agent set,
# finding 1) rather than gate_free_surface's own FREE_HELD_PATHS. gate_free_surface still runs,
# for FREE_UNCLAIMED_ISSUES only.
_GATE_SCRIPT = r"""
set -eu
owner="$1"; repo="$2"; free_surface_sh="$3"
# shellcheck source=/dev/null
source "$free_surface_sh"

# Same per-call timeout dispatch_free_surface_guard.sh already wraps gh in — a Stop hook is
# synchronous and gh has no default request deadline of its own.
gh() { timeout "${DISPATCH_PLAN_GH_TIMEOUT:-15}" gh "$@"; }

# stdin: the live-agent held paths, one per line, then a lone "===REQUESTS===" line, then every
# classify request as issue<TAB>file1|file2|... . Read before the network call below: neither
# gate_free_surface nor free_classify_files touches stdin, so this ordering is safe.
live_held=""
while IFS= read -r line; do
	[ "$line" = "===REQUESTS===" ] && break
	live_held="$(printf '%s\n%s' "$live_held" "$line")"
done
mapfile -t requests

if ! gate_free_surface "$owner" "$repo"; then
	echo "GATE_STATUS:unknown"
	exit 0
fi
echo "GATE_STATUS:ok"

# dotfiles-dev#433 finding 1: overwrite gate_free_surface's own agent-vs-open-PR held set with
# the caller's agent-vs-agent one before classifying.
FREE_HELD_PATHS="$(printf '%s\n' "$live_held" | sed '/^$/d' | sort -u)"

echo "===UNCLAIMED==="
printf '%s\n' "$FREE_UNCLAIMED_ISSUES"
echo "===RESULTS==="
for line in "${requests[@]}"; do
	[ -n "$line" ] || continue
	issue="${line%%$'\t'*}"
	files="${line#*$'\t'}"
	IFS='|' read -r -a filearr <<<"$files"
	verdict="$(free_classify_files "${filearr[@]}")"
	printf '%s\t%s\n' "$issue" "$verdict"
done
"""


def _run(cmd: list[str]) -> str:
	"""Run a command and return its stripped stdout.

	Raises on any non-zero exit or timeout, deliberately: a broken read here must surface as
	this script's own failure (see the module docstring's "fails loud" note), never as a
	silently empty answer.
	"""
	result = subprocess.run(  # noqa: S603 - fixed argv lists, no shell, no user input
		cmd, capture_output=True, text=True, timeout=GH_TIMEOUT, check=True
	)
	return result.stdout.strip()


# Anchored on the HOST, not just the shape: a bare `[:/]owner/name` tail also matches
# git@gitlab.com:team/project.git and would hand build_plan() a slug it then queries GitHub for —
# a plausible answer about a repository that is not this checkout (PR #545 review, Major). Any
# other origin falls through to `gh repo view`, which is the documented fallback and answers
# correctly for a GitHub Enterprise host this pattern deliberately does not try to guess.
SLUG_RE = re.compile(
	r"^(?:(?:https?|ssh|git)://)?(?:[^@/]+@)?github\.com[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$"
)


def repo_slug() -> str:
	"""Return ``owner/name`` for the repo rooted at the current working directory.

	Read from the local ``origin`` remote, not from the forge. The slug is a LOCAL fact and this
	was the first call ``build_plan()`` made, so asking GitHub for it made the whole planner
	unreadable during a GraphQL outage: ``gh repo view --json`` routes through GraphQL, and when
	that surface is refused the planner died here with an uncaught CalledProcessError, before it
	had read a single issue (dotfiles-dev#534). Measured 2026-09-27: GraphQL refused every call
	for over half an hour while ``git remote get-url`` answered instantly and REST was healthy.

	``gh repo view`` stays as the fallback for the one case the remote cannot answer — a checkout
	with no ``origin``, or a URL shape this does not match — so a working setup never regresses.
	"""
	try:
		url = _run(["git", "remote", "get-url", "origin"])
	except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
		url = ""
	match = SLUG_RE.search(url)
	if match:
		return f"{match.group(1)}/{match.group(2)}"
	return _run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])


def repo_root() -> Path:
	"""Return the working tree root, for expanding a declared surface's glob tokens."""
	return Path(_run(["git", "rev-parse", "--show-toplevel"]))


# dotfiles-dev#572: calls gate_live_agent_surface (free_surface.sh) via a subprocess, the same
# way run_gate() above already shells out to gate_free_surface — ONE liveness notion shared by
# both callers, rather than a second walk in Python that can (and did) drift from the shell
# gate's own dead-worktree exclusion (dotfiles-dev#551/#572). The gate resolves its own default
# branch from the local repo's `origin` remote, so this script no longer needs a separate
# `gh api repos/{slug} --jq .default_branch` call of its own.
_LIVE_AGENT_GATE_SCRIPT = r"""
set -eu
root="$1"; free_surface_sh="$2"
# shellcheck source=/dev/null
source "$free_surface_sh"

# Same per-call timeout run_gate() already wraps gh in.
gh() { timeout "${DISPATCH_PLAN_GH_TIMEOUT:-15}" gh "$@"; }

if ! gate_live_agent_surface "$root"; then
	echo "LIVE_AGENT_STATUS:unknown"
	exit 0
fi
echo "LIVE_AGENT_STATUS:ok"
printf '%s\n' "$LIVE_AGENT_PATHS"
"""


def live_agent_held_paths(root: Path) -> tuple[bool, list[str]]:
	"""Return ``(ok, held_paths)`` — files any OTHER live-agent worktree's branch has changed
	relative to the repo's default branch (dotfiles-dev#433 finding 1), via
	``gate_live_agent_surface`` (``hooks/lib/free_surface.sh``, dotfiles-dev#572).

	Delegating here — instead of this script re-walking ``git worktree list --porcelain``
	itself — is what gives this planner the same dead-worktree exclusion
	``gate_live_agent_surface`` already has (dotfiles-dev#551, and the ancestor extension added
	for dotfiles-dev#572): one shared, tested implementation of "is this worktree a live writer",
	never a second one that can independently drift.

	``ok=False`` on anything that leaves liveness undetermined (``gate_live_agent_surface``
	itself returning non-zero, a timeout, or a malformed reply) — never silently read as zero
	held paths, i.e. free.
	"""
	try:
		proc = subprocess.run(  # noqa: S603, S607 - fixed argv, script is a module constant
			["bash", "-c", _LIVE_AGENT_GATE_SCRIPT, "dispatch_plan", str(root), str(FREE_SURFACE_SH)],
			capture_output=True,
			text=True,
			timeout=GATE_TIMEOUT,
		)
	except subprocess.TimeoutExpired:
		return False, []

	lines = proc.stdout.splitlines()
	if proc.returncode != 0 or not lines or lines[0] != "LIVE_AGENT_STATUS:ok":
		return False, []
	return True, sorted(p for p in lines[1:] if p)


def _label_names(record: dict) -> list[str]:
	"""Return a REST issue record's label names, tolerating both shapes the API has used.

	REST normally returns each label as ``{"name": ..., ...}``; a bare string is also accepted
	defensively rather than raising, since a shape this function gets wrong would surface as a
	crash on an unrelated issue's labels, not as a blocked-state false negative on this one.
	"""
	names: list[str] = []
	for label in record.get("labels") or []:
		if isinstance(label, dict):
			name = label.get("name")
			if name:
				names.append(name)
		elif isinstance(label, str):
			names.append(label)
	return names


def open_issues(slug: str) -> list[dict]:
	"""Return every open issue's number, body, and label names for ``slug`` (``owner/name``).

	Capped at ``FREE_SURFACE_ISSUE_CAP`` — ``build_plan`` refuses to print a plan when the
	result hits that cap (dotfiles-dev#433 finding 2).

	Read over REST, never ``gh issue list --json``: that form routes through GraphQL, and it was the
	SECOND place this planner died during the GraphQL outage measured 2026-09-27 — immediately after
	``repo_slug()`` and for the same reason (dotfiles-dev#534). REST answered normally throughout, so
	the whole planner now survives an outage that only affects GraphQL.

	⚠️ REST's ``/issues`` returns PULL REQUESTS too — GitHub models a PR as an issue — so every
	record carrying ``pull_request`` is dropped. Measured on this repo the same day, one page held 22
	issues and 5 PRs: without the filter the planner would treat its own open PRs as dispatch
	candidates. ``gh issue list`` did that filtering for us; ``gh api`` does not.

	``--paginate`` merges pages into a single array (verified with ``per_page=5``, which returned all
	27 records), and the result is truncated to the cap so the refuse-at-the-cap behaviour keeps its
	original meaning: a full slice still means "there may be more than we read".
	"""
	raw = _run(
		[
			"gh",
			"api",
			"--paginate",
			f"repos/{slug}/issues?state=open&per_page=100",
		]
	)
	records = json.loads(raw) if raw else []
	issues = [
		{"number": r.get("number"), "body": r.get("body") or "", "labels": _label_names(r)}
		for r in records
		if "pull_request" not in r
	]
	return issues[:FREE_SURFACE_ISSUE_CAP]


def open_prs(slug: str) -> list[dict]:
	"""Return every open PR's number, title, body, and closing issue references for ``slug``.

	Feeds ``mentioned_without_closing`` only — a second, independent read from the ``gh api
	graphql`` call ``gate_free_surface`` already makes for ``FREE_UNCLAIMED_ISSUES``, because
	that call answers "does this PR close issue N" and never exposes the PR's own title/body
	text this function needs to answer a different question: "does this PR merely NAME issue
	N" (dotfiles-dev#413). Capped at ``OPEN_PR_LIST_CAP`` — ``build_plan`` refuses to print a
	plan when the result hits that cap, same contract as ``open_issues``/
	``FREE_SURFACE_ISSUE_CAP`` (PR #506 review: a truncated read can miss a PR that mentions a
	later issue, reading that issue as unmentioned rather than held).
	"""
	raw = _run(
		[
			"gh",
			"pr",
			"list",
			"--repo",
			slug,
			"--state",
			"open",
			"--json",
			"number,title,body,closingIssuesReferences",
			"--limit",
			str(OPEN_PR_LIST_CAP),
		]
	)
	return json.loads(raw) if raw else []


def mentioned_without_closing(issue_numbers: set[int], prs: list[dict], slug: str) -> dict[int, str]:
	"""Return ``{issue: reason}`` for every issue an open PR names without closing it.

	``closingIssuesReferences`` is the reliable oracle for "this PR WILL close that issue"
	(module docstring); a bare ``#N`` in the same PR's title or body without a closing keyword
	is neither closing it nor irrelevant — GitHub still renders it as a cross-reference, so
	dispatching #N risks a duplicate PR against real, in-review work (dotfiles-dev#413).

	Matches ``#N`` (word-boundary, so ``#12`` never matches inside ``#123``) and also ``<this
	repo's slug>#N`` (e.g. ``acme/widgets#361``, GitHub's own same-repository qualified
	reference syntax, matched case-insensitively the way GitHub itself treats a repo slug) —
	never a *different* repo's qualified reference (``other/repo#361`` says nothing about this
	repo's issue #361), and never a slug that is merely a SUFFIX of a longer word
	(``notacme/widgets#361`` must not match ``acme/widgets#361`` — requiring a non-word,
	non-slash character (or start of text) immediately before the slug rejects it, PR #506
	review).
	"""
	slug_re = re.escape(slug)
	reasons: dict[int, str] = {}
	for pr in prs:
		closing = {ref["number"] for ref in pr.get("closingIssuesReferences") or []}
		text = f"{pr.get('title') or ''}\n{pr.get('body') or ''}"
		for number in issue_numbers - closing:
			if number in reasons:
				continue
			pattern = rf"(?<!\w)#{number}(?!\d)|(?<![\w/]){slug_re}#{number}(?!\d)"
			if re.search(pattern, text, re.IGNORECASE):
				reasons[number] = (
					f"referenced by open PR #{pr['number']} without a closing keyword — "
					"verify by hand (missing `Closes`, or a deliberate stacked follow-up)"
				)
	return reasons


# Sources roadmap_unblock.sh and calls its OWN `_ru_native_blockers` per issue number read from
# stdin — never a re-derived `gh api .../dependencies/blocked_by` call. A fix to that function
# (pagination, jq parsing) reaches this planner the moment roadmap_unblock.sh changes instead of
# needing a second, independent edit here (dotfiles-dev#560's explicit ask).
_BLOCKED_SCRIPT = r"""
set -eu
repo="$1"; roadmap_unblock_sh="$2"
# shellcheck source=/dev/null
source "$roadmap_unblock_sh"

gh() { timeout "${DISPATCH_PLAN_GH_TIMEOUT:-15}" gh "$@"; }

while IFS= read -r number; do
	[ -n "$number" ] || continue
	if native="$(_ru_native_blockers "$repo" "$number")"; then
		printf '%s\tOK\t%s\n' "$number" "$(printf '%s' "$native" | tr '\n' ';')"
	else
		printf '%s\tFAIL\t\n' "$number"
	fi
done
"""


def native_open_blockers(slug: str, numbers: list[int]) -> dict[int, list[str] | None]:
	"""Return ``{issue: open_blocker_refs}`` from the native ``blocked_by`` relation.

	``open_blocker_refs`` is a list of ``owner/repo#number`` refs still open (empty means the
	native read succeeded and found none). ``None`` means the read itself failed for that issue
	— the caller's fail-closed signal, same contract as every other gate in this file: a failed
	read is UNKNOWN, never "not blocked".

	One subprocess for every issue, not one subprocess per issue: each call is a fresh ``gh`` API
	round-trip, and batching keeps this the same shape as ``run_gate``'s single free-surface
	subprocess rather than multiplying process-spawn and rate-limit cost by the open-issue count.
	"""
	if not numbers:
		return {}
	stdin = "".join(f"{n}\n" for n in numbers)
	try:
		proc = subprocess.run(  # noqa: S603, S607 - fixed argv, script is a module constant
			["bash", "-c", _BLOCKED_SCRIPT, "dispatch_plan", slug, str(ROADMAP_UNBLOCK_SH)],
			input=stdin,
			capture_output=True,
			text=True,
			timeout=BLOCKED_TIMEOUT,
		)
	except subprocess.TimeoutExpired:
		# Uncaught, this killed build_plan and printed no plan at all (#569 review) — a slow read
		# must exclude every issue as UNKNOWN, the same answer as a driver that broke.
		return dict.fromkeys(numbers, None)
	if proc.returncode != 0:
		# The driver itself broke (e.g. roadmap_unblock.sh failed to source) before it could even
		# report a per-issue FAIL line — every requested number is equally undetermined.
		return dict.fromkeys(numbers, None)

	result: dict[int, list[str] | None] = {}
	for line in proc.stdout.splitlines():
		if not line.strip():
			continue
		number_s, status, refs_s = line.split("\t", 2)
		number = int(number_s)
		if status != "OK":
			result[number] = None
			continue
		open_refs = []
		for entry in refs_s.split(";"):
			if not entry:
				continue
			state, _, ref = entry.partition("\t")
			if state != "closed":
				open_refs.append(ref)
		result[number] = open_refs
	return result


def blocked_reason(issue: dict, native_refs: list[str] | None) -> str | None:
	"""Return the exclusion reason for a blocked issue, or ``None`` when it is not blocked.

	Checked in the order dotfiles-dev#560 specifies: the native relation first (authoritative —
	it is what GitHub itself resolves on close), the ``state:blocked`` label second. A board-only
	``Status = Blocked`` is deliberately not a third source here (module docstring) — that
	mismatch belongs to `roadmap_unblock.sh`'s own reconcile step.
	"""
	if native_refs is None:
		return (
			"blocked-state UNKNOWN (native dependency read failed) — never assumed dispatchable"
		)
	if native_refs:
		return "blocked: open native dependency " + ", ".join(sorted(native_refs))
	if BLOCKED_LABEL in (issue.get("labels") or []):
		return (
			f"blocked: '{BLOCKED_LABEL}' label set (no open native dependency recorded — a "
			"roadmap_unblock reconcile gap, not cleared here)"
		)
	return None


def declared_surface(body: str) -> list[str]:
	"""Parse the fenced ```surface block out of an issue body into path/glob tokens.

	An absent block and an empty one return the same thing (``[]``) — the caller reads both
	as "no declared surface", never as "collides with nothing" (dotfiles-dev#426).
	"""
	match = SURFACE_BLOCK_RE.search(body or "")
	if not match:
		return []
	return [line.strip() for line in match.group(1).splitlines() if line.strip()]


def _walk_repo_files(root: Path) -> list[str]:
	"""List every file under ``root`` as a root-relative path, ``.git`` excluded.

	The one walk both sides of ``expand_tokens`` match a glob token against with
	``fnmatch`` — see that function's docstring for why ``root.glob`` was dropped.
	"""
	return [
		str(p.relative_to(root))
		for p in root.rglob("*")
		if p.is_file() and ".git" not in p.relative_to(root).parts
	]


def expand_tokens(tokens: list[str], root: Path, held: list[str]) -> list[str]:
	"""Expand each glob token against the repo tree AND the live-agent held-paths set.

	Both sides match with ``fnmatch`` — the issue template states the intended semantics
	("`*` matches across `/`, so `docs/*` and `docs/**` are equivalent"), which is what
	``fnmatch`` does and ``pathlib.Path.glob`` does not (``pathlib``'s `*` stops at `/`,
	and its `**` yields directories, not files — matching ``docs/**`` against the repo
	tree that way returned zero files while ``fnmatch`` matched everything under
	``docs/``, dotfiles-dev#549). Using one matcher for both sides means a token can no
	longer expand to two disagreeing answers depending on which side evaluates it.

	A live agent can add a file matching an issue's glob token on its own branch, invisible to
	the local walk since it never reaches this checkout (dotfiles-dev#433 finding 3) — matching
	the token against ``held`` too surfaces that collision instead of reading the issue as free.
	A literal (non-glob) token passes through unchanged whether or not it exists yet — an
	issue's declared surface may name a file its own solution would create. A token that
	matches nothing anywhere is kept as its literal pattern for the same reason, rather than
	silently dropped.
	"""
	files: list[str] = []
	local_files: list[str] | None = None
	for token in tokens:
		if any(ch in token for ch in GLOB_CHARS):
			if local_files is None:
				local_files = _walk_repo_files(root)
			local_matches = {p for p in local_files if fnmatch.fnmatch(p, token)}
			held_matches = {p for p in held if fnmatch.fnmatch(p, token)}
			matches = sorted(local_matches | held_matches)
			files.extend(matches or [token])
		else:
			files.append(token)
	return files


def run_gate(
	owner: str, repo: str, requests: list[tuple[int, list[str]]], held: list[str]
) -> tuple[bool, set[int], dict[int, str]]:
	"""Run gate_free_surface once (for the claimed-issue answer only) and classify every request
	against ``held`` — the live-agent-only set, not gate_free_surface's own — in one process.

	Returns ``(gate_ok, unclaimed_issue_numbers, {issue: classify_verdict})``. ``gate_ok`` is
	False exactly when gate_free_surface itself reported FREE_STATUS=unknown — a recoverable,
	expected condition (gh rate limit, an unhandled compare error), never a crash.
	"""
	stdin = "".join(f"{p}\n" for p in held)
	stdin += "===REQUESTS===\n"
	stdin += "".join(f"{issue}\t{'|'.join(files)}\n" for issue, files in requests)
	proc = subprocess.run(  # noqa: S603, S607 - fixed argv, script is a module constant
		["bash", "-c", _GATE_SCRIPT, "dispatch_plan", owner, repo, str(FREE_SURFACE_SH)],
		input=stdin,
		capture_output=True,
		text=True,
		timeout=GATE_TIMEOUT,
		check=True,
	)
	lines = proc.stdout.splitlines()
	if not lines or lines[0] != "GATE_STATUS:ok":
		return False, set(), {}

	results_at = lines.index("===RESULTS===")
	unclaimed = {int(n) for n in lines[2:results_at] if n.strip()}
	verdicts = {}
	for line in lines[results_at + 1 :]:
		if not line.strip():
			continue
		issue, verdict = line.split("\t", 1)
		verdicts[int(issue)] = verdict
	return True, unclaimed, verdicts


def select_disjoint(candidates: list[dict]) -> tuple[list[dict], list[dict]]:
	"""Greedily select the largest disjoint set of candidates and name every collision.

	Each issue is classified independently against the held set, so two issues declaring an
	overlapping free path both read individually free (dotfiles-dev#433 finding 4) — nothing
	reserves a selected candidate's paths before the next one is considered. This is a
	deterministic GREEDY pass over candidates sorted by surface size ascending (ties by issue
	number), not an optimal maximum-cardinality solver — sorting smallest-first means a single
	large candidate can never displace two smaller ones it only blocks, but a harder packing
	instance can still lose to the greedy choice. #433 explicitly allows this: "you do NOT need
	an optimal ... solver."
	"""
	ordered = sorted(candidates, key=lambda c: (len(c["surface"]), c["issue"]))
	reserved: set[str] = set()
	dispatchable: list[dict] = []
	excluded: list[dict] = []
	for cand in ordered:
		collision = reserved.intersection(cand["surface"])
		if collision:
			excluded.append(
				{
					"issue": cand["issue"],
					"reason": "collides with an already-selected candidate's surface: "
					+ sorted(collision)[0],
				}
			)
		else:
			dispatchable.append(cand)
			reserved.update(cand["surface"])
	dispatchable.sort(key=lambda c: c["issue"])
	return dispatchable, excluded


def build_plan() -> dict:
	"""Assemble the {"dispatchable": [...], "excluded": [...]} plan for every open issue."""
	slug = repo_slug()
	owner, name = slug.split("/", 1)
	root = repo_root()
	issues = open_issues(slug)
	if len(issues) >= FREE_SURFACE_ISSUE_CAP:
		raise RuntimeError(
			f"open issue count ({len(issues)}) is at or past the "
			f"{FREE_SURFACE_ISSUE_CAP}-issue cap this read and gate_free_surface's own "
			"claimed-issue read share (dotfiles-dev#433 finding 2) — a truncated read can "
			"misclassify a later issue as claimed; refusing to print a plan rather than a "
			"possibly wrong one"
		)

	issue_numbers = {issue["number"] for issue in issues}
	# `closingIssuesReferences` has no REST equivalent, so this one read stays on GraphQL and can be
	# refused while the rest of the planner is healthy (dotfiles-dev#534). Dying here printed nothing
	# at all, and both Stop guards then reported the plan UNREADABLE — true, but it hid a plan that
	# was otherwise fully computable. Excluding every candidate BY NAME with this reason is the
	# documented legitimate-zero shape: fail closed, stay readable, say which read failed.
	try:
		prs = open_prs(slug) if issue_numbers else []
	except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
		return {
			"dispatchable": [],
			"excluded": [
				{
					"issue": number,
					"reason": (
						"claimed-by-PR check UNREADABLE (gh pr list --json "
						"closingIssuesReferences refused — GraphQL) — never assumed free"
					),
				}
				for number in sorted(issue_numbers, reverse=True)
			],
		}
	if len(prs) >= OPEN_PR_LIST_CAP:
		raise RuntimeError(
			f"open PR count ({len(prs)}) is at or past the {OPEN_PR_LIST_CAP}-PR cap this "
			"read shares with its own --limit (PR #506 review) — a truncated read can miss "
			"a PR that mentions a later issue, misclassifying it as unmentioned; refusing to "
			"print a plan rather than a possibly wrong one"
		)
	mention_reasons = mentioned_without_closing(issue_numbers, prs, slug) if issue_numbers else {}

	live_ok, live_held = live_agent_held_paths(root)

	surfaces: dict[int, list[str]] = {}
	expanded: dict[int, list[str]] = {}
	for issue in issues:
		tokens = declared_surface(issue.get("body") or "")
		if tokens:
			number = issue["number"]
			surfaces[number] = tokens
			expanded[number] = expand_tokens(tokens, root, live_held)

	requests = list(expanded.items())
	if live_ok:
		gate_ok, unclaimed, verdicts = run_gate(owner, name, requests, live_held)
	else:
		gate_ok, unclaimed, verdicts = False, set(), {}

	# Only worth reading once the rest of the plan is actually usable — every issue below is
	# excluded on live_ok/gate_ok alone otherwise, and this read is never consulted for that.
	native_refs: dict[int, list[str] | None] = {}
	if live_ok and gate_ok and issue_numbers:
		native_refs = native_open_blockers(slug, sorted(issue_numbers))

	candidates: list[dict] = []
	excluded: list[dict] = []
	for issue in issues:
		number = issue["number"]
		reason = blocked_reason(issue, native_refs.get(number)) if live_ok and gate_ok else None
		if not live_ok:
			excluded.append(
				{
					"issue": number,
					"reason": "live-agent liveness UNKNOWN (worktree walk failed) — "
					"verify non-collision by hand",
				}
			)
		elif not gate_ok:
			excluded.append(
				{
					"issue": number,
					"reason": "free surface gate UNKNOWN (gh API failure) — "
					"verify non-collision by hand",
				}
			)
		elif reason is not None:
			excluded.append({"issue": number, "reason": reason})
		elif number not in unclaimed:
			excluded.append(
				{"issue": number, "reason": "already claimed by an open or merged pull request"}
			)
		elif number in mention_reasons:
			excluded.append({"issue": number, "reason": mention_reasons[number]})
		elif number not in surfaces:
			excluded.append({"issue": number, "reason": UNDECLARED_REASON})
		else:
			verdict = verdicts.get(number, "")
			if verdict == "free" or verdict.startswith("would-need-a-held-file"):
				candidates.append({"issue": number, "surface": expanded[number]})
			else:
				held_paths = (
					verdict.split(":", 1)[1] if ":" in verdict else "unreadable classify verdict"
				)
				excluded.append(
					{"issue": number, "reason": f"surface held by a live agent: {held_paths}"}
				)

	dispatchable, disjoint_excluded = select_disjoint(candidates)
	excluded.extend(disjoint_excluded)

	return {"dispatchable": dispatchable, "excluded": excluded}


def main() -> int:
	"""Print the dispatch plan as one JSON object and return 0."""
	print(json.dumps(build_plan()))
	return 0


if __name__ == "__main__":
	sys.exit(main())
