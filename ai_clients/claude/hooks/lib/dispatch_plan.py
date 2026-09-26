"""Compute the non-colliding dispatch set for round_dispatch_guard.sh (dotfiles-dev#433).

Invoked with NO arguments, from the current working directory — a checkout of the target
repo, the same convention round_dispatch_guard.sh's own ``python3 "$PLANNER"`` call relies
on (it never ``cd``s anywhere first). Prints exactly one JSON object to stdout::

    {"dispatchable": [{"issue": 433, "surface": ["a/b.py"]}],
     "excluded":     [{"issue": 426, "reason": "..."}]}

Collision is agent-vs-agent, never agent-vs-open-PR (dotfiles-dev#433; review findings on PR
#476). The held set fed to ``free_classify_files`` (``lib/free_surface.sh``, #340) is built
here from ``git worktree list`` — the same "which branches are live agents" notion
``hooks/lib/worktree_fanout.sh`` already owns for session_start_context.sh and
quota_gap_rescue.sh — never from ``gate_free_surface``'s own ``FREE_HELD_PATHS``, which unions
every open PR's files regardless of whether an agent is still live on it (a frozen/idle open PR
would otherwise suppress dispatch of an unrelated candidate). ``gate_free_surface`` is still
called for its OTHER answer: the claimed-issue check (``FREE_UNCLAIMED_ISSUES``) is
deliberately agent-vs-{open,merged}-PR, a different question ("is this issue already being
delivered") that this script leaves untouched. Collapsing ``would-need-a-held-file`` into
``held`` was the specific bug that hid 97% of a free directory behind a directory-level summary
(#340); the mapping below keeps all three classify states apart on purpose.

An issue's file surface is declared as a fenced ```surface block in its body — the
convention dotfiles-dev#426 formalises with an issue-template requirement; here it is
read, not enforced. An issue with no such block, or an empty one, is UNKNOWN, never
"collides with nothing": it is excluded with its own named reason, same as one whose
surface is held.

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
GH_TIMEOUT = 20
GATE_TIMEOUT = 25

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


def repo_slug() -> str:
	"""Return ``owner/name`` for the repo rooted at the current working directory."""
	return _run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])


def repo_root() -> Path:
	"""Return the working tree root, for expanding a declared surface's glob tokens."""
	return Path(_run(["git", "rev-parse", "--show-toplevel"]))


def default_branch(slug: str) -> str | None:
	"""Return ``slug``'s default branch name, or None on any failure (never raises).

	Same source ``_free_held_paths`` (free_surface.sh) reads its own default branch from — kept
	as a second, independent call rather than threading the value out of that sourced function,
	which is out of scope to edit for this change.
	"""
	try:
		branch = _run(["gh", "api", f"repos/{slug}", "--jq", ".default_branch"])
	except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
		return None
	return branch or None


def live_agent_held_paths(root: Path, default: str) -> tuple[bool, list[str]]:
	"""Return ``(ok, held_paths)`` — files any OTHER live-agent worktree's branch has changed
	relative to ``default`` (dotfiles-dev#433 finding 1).

	A "live agent" is a git worktree of this checkout — the same notion
	``hooks/lib/worktree_fanout.sh`` already walks via ``git worktree list --porcelain`` for
	session_start_context.sh and quota_gap_rescue.sh. That file exposes no standalone accessor
	for just the branch list (only printed alerts) and is out of scope to edit here, so this
	mirrors its own porcelain walk rather than inventing a different liveness signal (a pushed-
	branch scan, a naming convention, ...).

	``ok=False`` on anything that leaves liveness undetermined — a ``git worktree list``/``git
	diff`` failure that is not a plain "unrelated histories" orphan branch — never silently read
	as zero held paths, i.e. free.
	"""
	try:
		porcelain = _run(["git", "-C", str(root), "worktree", "list", "--porcelain"])
	except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
		return False, []

	held: set[str] = set()
	branch = ""
	prefix = "branch refs/heads/"
	for line in [*porcelain.splitlines(), ""]:
		if line.startswith(prefix):
			branch = line[len(prefix) :]
			continue
		if line != "":
			continue
		if branch and branch != default:
			diff = subprocess.run(  # noqa: S603, S607 - fixed argv, no shell
				["git", "-C", str(root), "diff", "--name-only", f"{default}...{branch}"],
				capture_output=True,
				text=True,
				timeout=GH_TIMEOUT,
			)
			if diff.returncode != 0:
				stderr = diff.stderr.lower()
				if "merge base" not in stderr and "unknown revision" not in stderr:
					return False, []
			else:
				held.update(p for p in diff.stdout.splitlines() if p)
		branch = ""
	return True, sorted(held)


def open_issues(slug: str) -> list[dict]:
	"""Return every open issue's number and body for ``slug`` (``owner/name``).

	Capped at ``FREE_SURFACE_ISSUE_CAP`` — ``build_plan`` refuses to print a plan when the
	result hits that cap (dotfiles-dev#433 finding 2).
	"""
	raw = _run(
		[
			"gh",
			"issue",
			"list",
			"--repo",
			slug,
			"--state",
			"open",
			"--limit",
			str(FREE_SURFACE_ISSUE_CAP),
			"--json",
			"number,body",
		]
	)
	return json.loads(raw) if raw else []


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


def declared_surface(body: str) -> list[str]:
	"""Parse the fenced ```surface block out of an issue body into path/glob tokens.

	An absent block and an empty one return the same thing (``[]``) — the caller reads both
	as "no declared surface", never as "collides with nothing" (dotfiles-dev#426).
	"""
	match = SURFACE_BLOCK_RE.search(body or "")
	if not match:
		return []
	return [line.strip() for line in match.group(1).splitlines() if line.strip()]


def expand_tokens(tokens: list[str], root: Path, held: list[str]) -> list[str]:
	"""Expand each glob token against the repo tree AND the live-agent held-paths set.

	A live agent can add a file matching an issue's glob token on its own branch, invisible to
	``root.glob`` since it never reaches this checkout (dotfiles-dev#433 finding 3) — matching
	the token against ``held`` too (``fnmatch``) surfaces that collision instead of reading the
	issue as free. A literal (non-glob) token passes through unchanged whether or not it exists
	yet — an issue's declared surface may name a file its own solution would create. A token
	that matches nothing anywhere is kept as its literal pattern for the same reason, rather
	than silently dropped.
	"""
	files: list[str] = []
	for token in tokens:
		if any(ch in token for ch in GLOB_CHARS):
			local_matches = {str(p.relative_to(root)) for p in root.glob(token)}
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
	prs = open_prs(slug) if issue_numbers else []
	if len(prs) >= OPEN_PR_LIST_CAP:
		raise RuntimeError(
			f"open PR count ({len(prs)}) is at or past the {OPEN_PR_LIST_CAP}-PR cap this "
			"read shares with its own --limit (PR #506 review) — a truncated read can miss "
			"a PR that mentions a later issue, misclassifying it as unmentioned; refusing to "
			"print a plan rather than a possibly wrong one"
		)
	mention_reasons = mentioned_without_closing(issue_numbers, prs, slug) if issue_numbers else {}

	default = default_branch(slug)
	live_ok, live_held = live_agent_held_paths(root, default) if default else (False, [])

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

	candidates: list[dict] = []
	excluded: list[dict] = []
	for issue in issues:
		number = issue["number"]
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
		elif number not in unclaimed:
			excluded.append(
				{"issue": number, "reason": "already claimed by an open or merged pull request"}
			)
		elif number in mention_reasons:
			excluded.append({"issue": number, "reason": mention_reasons[number]})
		elif number not in surfaces:
			excluded.append(
				{
					"issue": number,
					"reason": "no declared file surface (no ```surface block in the issue body)",
				}
			)
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
