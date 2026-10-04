#!/bin/bash
# PreToolUse (Bash matcher) hook: enforce the repo PR template on `gh pr create` / `gh pr edit`.
#
# Why this exists: the "a PR body must follow .github/PULL_REQUEST_TEMPLATE.md" rule recurred 7+
# times from memory/lessons alone — advisory context cannot enforce. This hook is harness-run, so
# it cannot be skipped. It BLOCKS (exit 2) a gh-pr call whose --body is missing template sections,
# feeding the template back so the body is recomposed; a compliant body passes untouched.
#
# Hook I/O contract (deliberately NOT the usual script convention): this file must stay silent on
# stdout and speak only through exit code + stderr — so there is intentionally no lib/common.sh /
# print_status here. It also fails OPEN everywhere: any uncertainty exits 0, so it can never wedge
# unrelated Bash calls.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gh_body_guard_common.sh
source "$SCRIPT_DIR/lib/gh_body_guard_common.sh"

# Fail open if jq (used to parse the hook payload) is unavailable.
command -v jq >/dev/null 2>&1 || exit 0

main() {
    local payload tool command template body_source header line
    local missing=() root

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    # Find a `[rtk] gh pr create|edit` invocation by real argv, not by scanning raw text: a regex
    # anchored to the START of the command missed every invocation chained after `;`/`&&`/`||`/
    # `|`/`&`/a newline, and could be fooled by "--repo"/"--body" text appearing inside an
    # unrelated quoted argument like --title (CodeRabbit review, PR #371). This is ALSO what keeps
    # `gh issue create` untouched (dotfiles-linux-dev#154 defect 1): "pr" is a required argv position
    # here, so an issue command never matches.
    resolve_gh_command "$command" "pr" || exit 0   # unparseable → unknown, not non-compliant
    [[ "$GH_MATCHED" == "true" ]] || exit 0
    # Only when a body is actually being set (skip title-only edits, editor-mode create, --fill).
    [[ "$GH_HAS_BODY" == "true" || "$GH_HAS_BODY_FILE" == "true" ]] || exit 0

    # Resolve the TARGET repo's template, not the session cwd's (dotfiles-linux-dev#154 defect 2). A
    # `--repo`/`-R owner/name` on the gh command itself always wins over cwd — the command can
    # target a different repo than the session is sitting in (`cd other-repo; gh pr create --repo
    # this-repo ...` is routine in a multi-repo session), and judging it against the wrong repo's
    # template is worse than not judging it at all (it fails in the *permitting* direction too).
    if [[ -n "$GH_REPO" ]]; then
        root="$HOME/github/${GH_REPO##*/}"
        [[ -d "$root/.git" ]] || block_unresolved_repo "$GH_REPO" "$root"
        template="$(find_template "$root" 0)"   # no personal-template fallback for a foreign repo
    else
        root="$(git rev-parse --show-toplevel 2>/dev/null)"
        template="$(find_template "$root" 1)"
    fi
    [[ -n "$template" && -r "$template" ]] || exit 0   # no template anywhere → nothing to enforce

    # Inspect the --body-file contents if given, else the inline --body value (which embeds the
    # section headers directly).
    #
    # A --body-file/-F flag that we cannot resolve to a readable file is NOT the same as "no
    # body-file" (dotfiles-linux-dev#78): falling back to scanning the command string then produces a
    # verdict from the wrong source — it can false-PASS when the header texts happen to appear in
    # e.g. --title, or block with a misleading "missing sections". A verdict from unresolved input
    # is "unknown", not "approved": fail loud instead.
    if [[ "$GH_HAS_BODY_FILE" == "true" ]]; then
        if [[ -r "$GH_BODY_FILE" ]]; then
            body_source="$(cat "$GH_BODY_FILE")"
        else
            block_unresolved_body_file "$GH_BODY_FILE" "$root"
        fi
    else
        body_source="$GH_BODY"
    fi

    # Every `## Heading` in the template must appear (by its text) in the body.
    while IFS= read -r line; do
        header="$(printf '%s' "$line" | sed -E 's/^#+[[:space:]]*//; s/[[:space:]]+$//')"
        [[ -n "$header" ]] || continue
        printf '%s' "$body_source" | grep -qiF -- "$header" || missing+=("$header")
    done < <(grep -E '^##[[:space:]]' "$template" 2>/dev/null)

    [[ ${#missing[@]} -eq 0 ]] && exit 0   # compliant → allow

    {
        echo "BLOCKED: this PR body does not follow the repository's PR template."
        echo "Template: $template"
        echo
        echo "Missing required sections:"
        for header in "${missing[@]}"; do
            echo "  - $header"
        done
        echo
        echo "Re-run the SAME gh command with a --body that fills EVERY section below:"
        echo "-----8<----- PULL_REQUEST_TEMPLATE -----8<-----"
        cat "$template"
        echo "-----8<----------------------------------8<-----"
    } >&2
    exit 2
}

# $1: repo root to search (may be empty). $2: 1 to fall back to the canonical personal template
# when the root ships none, 0 to skip that fallback. The fallback is only correct for the
# session's OWN repo — imposing a personal template preference onto an unrelated --repo target
# would be a scope overreach the caller (main) must opt out of explicitly (dotfiles-linux-dev#154).
find_template() {
    local root="$1" allow_personal_fallback="${2:-1}" candidate multi
    if [[ -n "$root" ]]; then
        for candidate in \
            "$root/.github/PULL_REQUEST_TEMPLATE.md" \
            "$root/.github/pull_request_template.md" \
            "$root/docs/PULL_REQUEST_TEMPLATE.md" \
            "$root/PULL_REQUEST_TEMPLATE.md"; do
            [[ -r "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
        done
        multi="$(find "$root/.github/PULL_REQUEST_TEMPLATE" -maxdepth 1 -iname '*.md' 2>/dev/null \
            | sort | head -n1)"
        [[ -n "$multi" && -r "$multi" ]] && { printf '%s' "$multi"; return 0; }
    fi
    [[ "$allow_personal_fallback" -eq 1 ]] || return 0   # target repo has no template → pass
    # Canonical personal fallback when the repo ships no template.
    local fallback="$HOME/.claude/projects/-home-guilhermegor-github-dotfiles-dev/memory/feedback_pr_template.md"
    [[ -r "$fallback" ]] && { printf '%s' "$fallback"; return 0; }
    return 0
}

block_unresolved_repo() {
    # A verdict from a template we could not locate is "unknown", not "approved" — same principle
    # as block_unresolved_body_file below. This must never share text with the "Missing required
    # sections" block: "I couldn't check" and "I checked and it's wrong" are different states.
    local target="$1" tried="$2"
    {
        echo "BLOCKED: could not resolve the PR template for --repo $target."
        echo
        echo "This gh command targets a different repository than the session's cwd. Its local"
        echo "checkout was expected at $tried but was not found there, so this repo's"
        echo ".github/PULL_REQUEST_TEMPLATE.md could not be read."
        echo
        echo "This is NOT a verdict on the PR body — the template could not be located, so"
        echo "nothing was checked."
        echo
        echo "Clone the repo to $tried (or correct the --repo value), then re-run the SAME"
        echo "gh command."
    } >&2
    exit 2
}

block_unresolved_body_file() {
    # A PreToolUse hook sees the command BEFORE shell expansion, AND runs sandboxed to the
    # project directory — either fact alone can make an otherwise-fine --body-file unreadable
    # HERE while the file is perfectly readable everywhere else. A generic "check the path" then
    # sends the author chasing a typo or permission bug that does not exist (dotfiles-linux-dev#109),
    # so name the actual cause: an unexpanded shell variable, a path outside the project
    # directory (this hook's filesystem view is sandboxed to the project — dotfiles-linux-dev#109), or
    # the file genuinely not existing yet (dotfiles-linux-dev#78, e.g. create-and-consume in one call).
    local path="$1" root="${2:-}"

    {
        echo "BLOCKED: the --body-file could not be read, so the PR body was never verified."
        echo
        echo "A --body-file/-F was passed but does not resolve to a readable file. A template"
        echo "verdict derived from any other source (the command line, the --title) would be a"
        echo "guess, not a check — so this fails loud instead of rescanning silently."
        if [[ "$path" == *'$'* || "$path" == *'`'* ]]; then
            echo
            echo "The path contains an unexpanded shell variable or \$(…) — this hook sees the"
            echo "command before the shell expands it, so that advice would ALSO arrive"
            echo "unexpanded. Pass a literal path instead, or inline the literal body text with"
            echo "--body \"...\" (written out, not produced by a substitution)."
        elif [[ -n "$root" && "$path" == /* && "$path" != "$root"/* ]]; then
            echo
            echo "The path is outside the project directory ($root), which this hook cannot"
            echo "read — its filesystem view is sandboxed to the project. Move the file inside"
            echo "the repo instead — but NOT into $root/.git/: inside a git worktree, .git is a"
            echo "plain FILE (not a directory), so a write there fails outright, and a body left"
            echo "there anyway has no lifecycle (dotfiles-linux-dev#441). Use a root-level"
            echo "$root/.git-pr-<slug>.md file instead — already git-ignored (see .gitignore's"
            echo "'.git-pr-*.md' entry) and a real writable path in every checkout, worktree or"
            echo "not — then re-run the SAME gh command with the new path."
        else
            echo
            echo "If the file is created and consumed in the same command (e.g. \`cat >file &&"
            echo "gh pr create --body-file file\`), this hook still sees the pre-write state —"
            echo "write the file in a prior, separate step, then re-run this command. Otherwise"
            echo "check the path exists and is readable, then re-run the SAME gh command."
        fi
    } >&2
    exit 2
}

main "$@"
