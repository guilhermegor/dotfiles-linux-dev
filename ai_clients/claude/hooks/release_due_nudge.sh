#!/bin/bash
# PostToolUse (Bash matcher) hook: nudge when a release is DUE — the release that gets FORGOTTEN.
#
# Why this exists, and why it is separate from release_dispatch_guard.sh: the guard is a PreToolUse
# on the release *dispatch*, so it only fires once you are ALREADY publishing. It stops the WRONG
# release (a byte-identical wheel); it cannot stop the MISSING one — if a feat: landed in the shipped
# package and nobody remembered to publish, no tool call happens and nothing warns. So this hook
# watches for the two Bash tool calls that put a release in the DUE state:
#
#   1. A local `main`/`master` sync (`git pull`/`checkout`/`switch`) — the historical trigger.
#   2. A `gh pr merge` — the NORMAL way work lands (dotfiles-linux-dev#156). It runs server-side and never
#      touches local HEAD, so it needed its own detection instead of falling under (1). A merge done
#      through the GitHub web UI still can't be observed here (not a tool call at all) — that gap is
#      real but out of scope for a hook.
#
# It reads the SAME shipped-paths source as the guard and the s:release skill (.claude/release.conf,
# default src/ + pyproject.toml): if the three lists diverge they contradict each other — the
# explicit trap of the release-only-when-shipped-package-changes lesson. The suggested version here
# is OFFLINE and ADVISORY only; the authoritative next-version-across-both-indices computation stays
# in the skill (it needs the network). This hook just points at the gap.
#
# Hook I/O contract: PostToolUse, so the tool already ran — this never blocks. It fails OPEN
# everywhere (no jq, no gh, not a watched command, no tags, not a publishable repo, any error) by
# exiting 0 silently; when a release is due (or clearly not) it emits an additionalContext note.
# Never exits non-zero.

set -u

command -v jq >/dev/null 2>&1 || exit 0

main() {
    local payload tool command root

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

    # "Publishable repo" gate: a package to release has an explicit release.conf or a pyproject.toml.
    # Without either, this repo ships no wheel (dotfiles-dev itself is one) — stay silent.
    [[ -r "$root/.claude/release.conf" || -e "$root/pyproject.toml" ]] || exit 0

    if is_main_sync "$command"; then
        nudge_from_local_sync "$root"
    elif is_pr_merge "$command"; then
        nudge_from_pr_merge "$root" "$command"
    fi
}

is_main_sync() {
    # A sync of `main`: `git pull`, or `git checkout|switch` (both optionally rtk-prefixed). The
    # on-main check in nudge_from_local_sync confirms this actually landed us on main/master.
    local cmd="$1"
    printf '%s' "$cmd" \
        | grep -Eq '^[[:space:]]*(rtk[[:space:]]+)?git[[:space:]]+(pull|checkout|switch)([[:space:]]|$)'
}

is_pr_merge() {
    # `gh pr merge`, optionally rtk-prefixed. Matches with or without an explicit PR number, any
    # merge-method flag (--squash/--merge/--rebase), and --repo — those are all trailing args.
    local cmd="$1"
    printf '%s' "$cmd" \
        | grep -Eq '^[[:space:]]*(rtk[[:space:]]+)?gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
}

nudge_from_local_sync() {
    # Only nudge once we are actually ON main/master — a `git pull` on a feature branch, or a
    # `checkout -b`, matches the verb but is not a main sync. The current-branch check filters those
    # instead of brittle-parsing the command's arguments.
    local root="$1" branch
    branch="$(git symbolic-ref --short HEAD 2>/dev/null)" || exit 0
    [[ "$branch" == "main" || "$branch" == "master" ]] || exit 0
    check_release_due "$root" "HEAD"
}

nudge_from_pr_merge() {
    # `gh pr merge` runs server-side: it never moves local HEAD, and the caller isn't necessarily on
    # main. So instead of the branch check above, ask GitHub what actually happened — the merge
    # state and its base branch — rather than assume success from the command having been run.
    local root="$1" command="$2" number base
    command -v gh >/dev/null 2>&1 || exit 0

    number="$(pr_number_from_command "$command")"
    base="$(merged_pr_base "$number")" || exit 0
    [[ "$base" == "main" || "$base" == "master" ]] || exit 0

    # The local main/master may not have been synced in a long time, or ever, under worktrees — never
    # trust it. Force-update the remote-tracking ref to the real thing and diff against THAT: a stale
    # local main would otherwise make the shipped-diff check report a false "nothing changed".
    git fetch --quiet origin "+refs/heads/$base:refs/remotes/origin/$base" 2>/dev/null || exit 0
    check_release_due "$root" "origin/$base"
}

pr_number_from_command() {
    # First bare integer token in the command is the PR number; empty when omitted, which leaves
    # merged_pr_base() to resolve the PR the same way `gh pr merge` itself does with no number: the
    # PR associated with the current branch.
    local cmd="$1"
    printf '%s' "$cmd" | grep -Eo '[0-9]+' | head -1
}

merged_pr_base() {
    # Ground truth from the API: MERGED state + its base branch, or failure if not merged / not
    # resolvable (no PR context, network, auth) — never inferred from the Bash command having run.
    local number="$1" json
    local -a args=(pr view)
    [[ -n "$number" ]] && args+=("$number")
    # gh's --json flag takes ONE comma-separated field list, not multiple array elements.
    # shellcheck disable=SC2054
    args+=(--json state,baseRefName)

    json="$(gh "${args[@]}" 2>/dev/null)" || return 1
    [[ -n "$json" ]] || return 1
    [[ "$(printf '%s' "$json" | jq -r '.state')" == "MERGED" ]] || return 1
    printf '%s' "$json" | jq -r '.baseRefName'
}

check_release_due() {
    local root="$1" ref="$2" last_tag signal next
    local -a paths

    # No tags at all (fresh repo): describe fails, we exit silently — there is no floor to bump
    # from, so "since the last release" is undefined and this hook has nothing to say (the s:release
    # skill's first-publish path handles that case, not this advisory hook).
    # `--abbrev=0` also guarantees last_tag is reachable from ref (git describe only walks ref's own
    # ancestry), so it is always an ancestor of ref by construction — the "tag not an ancestor of
    # HEAD" edge case cannot arise from how last_tag is derived here.
    last_tag="$(git describe --tags --abbrev=0 "$ref" 2>/dev/null)" || exit 0

    mapfile -t paths < <(shipped_paths "$root")
    if shipped_diff_empty "$last_tag" "$ref" "${paths[@]}"; then
        announce_none
        exit 0
    fi
    if semantic_diff_empty "$last_tag" "$ref" "${paths[@]}"; then
        announce_none_comment_only
        exit 0
    fi

    signal="$(highest_signal "$last_tag" "$ref" "${paths[@]}")"
    next="$(next_version "$last_tag" "$signal")" || { announce_none; exit 0; }
    announce_due "$next" "$signal"
}

shipped_paths() {
    # One path/glob per line: the repo's .claude/release.conf if present, else the Python default.
    # IDENTICAL to release_dispatch_guard.sh's shipped_paths — the guard, this nudge, and the skill
    # MUST read the same list or they contradict each other.
    local root="$1" conf="$1/.claude/release.conf"
    if [[ -r "$conf" ]]; then
        grep -vE '^[[:space:]]*(#|$)' "$conf"
        return
    fi
    printf '%s\n' "src/" "pyproject.toml"
}

shipped_diff_empty() {
    local last_tag="$1" ref="$2"; shift 2
    local out
    out="$(git diff --name-only "$last_tag".."$ref" -- "$@" 2>/dev/null)" || return 1
    [[ -z "$out" ]]
}

semantic_diff_empty() {
    # True only when EVERY changed shipped-path file is a tracked .py file whose AST is identical
    # across revisions (dotfiles-linux-dev#100). A non-empty byte diff proves "these files were touched",
    # never "the artifact changed": a comment/docstring/formatting-only edit is non-empty in bytes
    # and AST-identical under ast.dump(). This check is Python-only by construction — ast.dump()
    # has no equivalent here for any other language — so it FAILS TOWARD "real change" for anything
    # it cannot certify: a non-.py file, an added/deleted file, or a file python3/ast cannot parse.
    # IDENTICAL to release_dispatch_guard.sh's semantic_diff_empty — the guard, this nudge, and the
    # s:release skill must agree on what "semantically empty" means, or they contradict each other.
    # Caller must already know the byte diff (shipped_diff_empty above) is non-empty.
    local last_tag="$1" ref="$2"; shift 2
    local -a changed
    mapfile -t changed < <(git diff --name-only "$last_tag".."$ref" -- "$@" 2>/dev/null)

    command -v python3 >/dev/null 2>&1 || return 1   # cannot certify -> treat as real change

    local file
    for file in "${changed[@]}"; do
        [[ "$file" == *.py ]] || return 1            # non-Python shipped file -> always real
        ast_identical "$last_tag" "$ref" "$file" || return 1
    done
    return 0
}

ast_identical() {
    # AST-equality of one file's content between two revisions. Returns failure (not identical) on
    # anything this check cannot certify: the file missing at either revision (added/deleted), or
    # unparseable/undecodable content at either revision — never silently reads an uncertain case
    # as "unchanged".
    local old_ref="$1" new_ref="$2" file="$3" old_tmp new_tmp rc
    old_tmp="$(mktemp)" && new_tmp="$(mktemp)" || return 1
    if ! git show "${old_ref}:${file}" >"$old_tmp" 2>/dev/null; then
        rm -f "$old_tmp" "$new_tmp"
        return 1
    fi
    if ! git show "${new_ref}:${file}" >"$new_tmp" 2>/dev/null; then
        rm -f "$old_tmp" "$new_tmp"
        return 1
    fi

    python3 - "$old_tmp" "$new_tmp" <<'PYEOF'
import ast
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        old_src = f.read()
    with open(sys.argv[2], encoding="utf-8") as f:
        new_src = f.read()
    same = ast.dump(ast.parse(old_src)) == ast.dump(ast.parse(new_src))
except (SyntaxError, UnicodeDecodeError, OSError, ValueError):
    sys.exit(1)
sys.exit(0 if same else 1)
PYEOF
    rc=$?
    rm -f "$old_tmp" "$new_tmp"
    return $rc
}

highest_signal() {
    # breaking > feat > fix > none, over commit subjects+bodies since the tag — but ONLY commits
    # that touched a shipped path (dotfiles-linux-dev#99: scanning every commit inflates the bump, e.g. a
    # feat(ci) that never touched the package still proposed a MINOR). Same "$@" paths as
    # shipped_diff_empty() above, passed through to git log's own pathspec filter: `A..B -- <paths>`
    # already restricts to commits whose diff intersects <paths>, so the two checks ("did the
    # artifact change" and "what type of change was it") can never disagree about which commits
    # count — no separate per-commit diff-tree loop needed.
    local last_tag="$1" ref="$2"; shift 2
    local log
    log="$(git log "$last_tag".."$ref" --format='%s%n%b' -- "$@" 2>/dev/null)" || { printf 'none'; return; }
    printf '%s' "$log" | grep -Eq 'BREAKING[ -]CHANGE|^[a-z]+(\([^)]*\))?!:' && { printf 'breaking'; return; }
    printf '%s' "$log" | grep -Eq '^feat(\([^)]*\))?:' && { printf 'feat'; return; }
    printf '%s' "$log" | grep -Eq '^fix(\([^)]*\))?:' && { printf 'fix'; return; }
    printf 'none'
}

next_version() {
    # Suggested next version from the last tag + highest commit signal, honouring the decision table
    # of the release-only-when-shipped-package-changes lesson:
    #   pre-1.0 (major==0): breaking → MINOR; feat/fix → PATCH
    #   >=1.0:              breaking → MAJOR; feat → MINOR; fix → PATCH
    # Returns 1 for signal "none" (nothing to release) or an unparseable tag.
    local last_tag="$1" signal="$2" sv major minor patch
    # `<<<` (not process substitution): semver prints no trailing newline, and `read` from a
    # newline-less stream returns non-zero at EOF even after assigning — a herestring adds the
    # delimiter so the exit code is honest.
    sv="$(semver "$last_tag")" || return 1
    read -r major minor patch <<< "$sv"
    case "$signal" in
        breaking)
            if (( major == 0 )); then minor=$((minor + 1)); patch=0
            else major=$((major + 1)); minor=0; patch=0; fi ;;
        feat)
            if (( major == 0 )); then patch=$((patch + 1))
            else minor=$((minor + 1)); patch=0; fi ;;
        fix)
            patch=$((patch + 1)) ;;
        *)  return 1 ;;
    esac
    printf '%s.%s.%s' "$major" "$minor" "$patch"
}

semver() {
    # Emit "MAJOR MINOR PATCH" from vX.Y.Z / X.Y.Z (pre-release/build suffix ignored); fail if the
    # core three numbers are not present.
    local v="${1#v}"
    [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
    printf '%s %s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

announce_due() {
    jq -n --arg v "$1" --arg s "$2" '{
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: ("RELEASE DUE: \($v) (\($s)) — the shipped artifact changed since the last tag but has not been released. Run the s:release skill to publish (it detects the ecosystem and gets the authoritative version floor from that arm; \($v) here is an offline hint).")
        }
    }' 2>/dev/null || true
}

announce_none() {
    jq -n '{
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: "NO RELEASE NEEDED (ci/docs only) — no shipped-artifact change since the last tag."
        }
    }' 2>/dev/null || true
}

announce_none_comment_only() {
    jq -n '{
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: "NO RELEASE NEEDED (shipped diff is comment-only) — the shipped .py files changed in bytes but are AST-identical across revisions: comments, docstring prose, or formatting only, zero change observable to a consumer. This check covers .py files only; any non-.py shipped file in the diff is always treated as a real change."
        }
    }' 2>/dev/null || true
}

main "$@"
