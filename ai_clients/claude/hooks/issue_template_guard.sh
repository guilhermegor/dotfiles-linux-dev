#!/bin/bash
# PreToolUse (Bash matcher) hook: enforce a repo's ISSUE_TEMPLATE(s) on `gh issue create` /
# `gh issue edit` — the same mechanism pr_template_guard.sh already applies to PR bodies, aimed at
# .github/ISSUE_TEMPLATE/*.md instead of .github/PULL_REQUEST_TEMPLATE.md.
#
# Generic and data-driven: a target repo with no issue template is untouched (exit 0) — this is
# what keeps `/issue` (ai_clients/claude/commands/issue.md), which files its own Goal/Scope/
# Documentation body into repos that ship no issue template (dotfiles-dev, blueprintx, ...), from
# ever hitting this guard. Nothing here names a specific repo or template.
#
# What is checked, all DERIVED FROM THE TEMPLATE FILE ITSELF, never hardcoded to one project's
# wording:
#   1. If the template's first non-empty content line is bold (starts with `**`), the body's
#      first non-empty line must be bold too. If that template line also contains a `·`
#      separator, the body's first line must contain one too.
#   2. Every `##`/`###` header in the template must appear (by text) in the body — same rule
#      pr_template_guard.sh already applies to `##` PR-template sections.
#   3. If the template's section under a header contains a `- [ ]` checklist item, the body's
#      matching section must contain at least one checklist item too.
#   4. A one-line directive inside the template's HTML comment can declare an EXTRA required
#      line, optionally gated on a label:
#          issue-template-guard: require "<literal text>" [if-label <label>]
#      Without `if-label`, the literal is always required. With it, the requirement is enforced
#      only when the label is POSITIVELY known to be on the issue from this command's own
#      `--label`/`-l`/`--add-label` flags (comma-separated, repeatable) — `gh issue create`'s
#      `--label` fully states the new issue's label set, but `gh issue edit` only ever reveals
#      labels being ADDED, never the issue's current set, so a directive whose label cannot be
#      determined this way is skipped (fails OPEN), never enforced on a guess.
#
# Several templates in one repo: a body passes if it satisfies ANY ONE of them — an issue follows
# one template, not all.
#
# Hook I/O contract (same as pr_template_guard.sh, deliberately NOT the usual script convention):
# stays silent on stdout, speaks only through exit code + stderr. Fails OPEN everywhere except the
# two spots pr_template_guard.sh also fails loud on purpose: an unresolved --repo target checkout,
# and a --body-file/-F that does not resolve to a readable file — both are "unknown", not
# "approved", so a verdict from either is refused rather than guessed.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gh_body_guard_common.sh
source "$SCRIPT_DIR/lib/gh_body_guard_common.sh"

# Fail open if jq (used to parse the hook payload) is unavailable.
command -v jq >/dev/null 2>&1 || exit 0

main() {
    local payload tool command root body_source labels
    local -a templates=() best_missing=()
    local template best_template="" best_count=-1

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    # Find a `[rtk] gh issue create|edit` invocation by real argv, not by scanning raw text —
    # mirrors pr_template_guard.sh's resolve_gh_command call exactly (see its comment for the
    # bypasses a start-anchored regex missed: chained after `;`/`&&`/`||`/`|`/`&`/a newline, or
    # fooled by flag-shaped text inside an unrelated quoted argument).
    resolve_gh_command "$command" "issue" || exit 0   # unparseable → unknown, not non-compliant
    [[ "$GH_MATCHED" == "true" ]] || exit 0
    # Only when a body is actually being set (skip title/label-only edits, editor-mode create).
    [[ "$GH_HAS_BODY" == "true" || "$GH_HAS_BODY_FILE" == "true" ]] || exit 0

    # Resolve the TARGET repo, not the session cwd's, mirroring pr_template_guard.sh exactly —
    # a `--repo`/`-R owner/name` on the command always wins over cwd.
    if [[ -n "$GH_REPO" ]]; then
        root="$(git rev-parse --show-toplevel 2>/dev/null)"
        if ! origin_names_repo "$GH_REPO"; then
            root="$HOME/github/${GH_REPO##*/}"
            [[ -d "$root/.git" ]] || block_unresolved_repo "$GH_REPO" "$root"
        fi
    else
        root="$(git rev-parse --show-toplevel 2>/dev/null)"
    fi

    mapfile -t templates < <(find_issue_templates "$root")
    [[ ${#templates[@]} -gt 0 ]] || exit 0   # no issue template anywhere → nothing to enforce

    if [[ "$GH_HAS_BODY_FILE" == "true" ]]; then
        if [[ -r "$GH_BODY_FILE" ]]; then
            body_source="$(cat "$GH_BODY_FILE")"
        else
            block_unresolved_body_file "$GH_BODY_FILE" "$root"
        fi
    else
        body_source="$GH_BODY"
    fi
    # Tolerate a literal two-character `\n` inside an inline --body (as opposed to a real
    # newline) so the section-aware checks below still see line structure either way.
    body_source=${body_source//'\n'/$'\n'}

    labels="$(printf '%s\n' "${GH_LABELS[@]}")"

    for template in "${templates[@]}"; do
        evaluate_template "$template" "$body_source" "$labels"
        if [[ ${#missing[@]} -eq 0 ]]; then
            exit 0   # this template is fully satisfied → allow
        fi
        if [[ $best_count -eq -1 || ${#missing[@]} -lt $best_count ]]; then
            best_count=${#missing[@]}
            best_template="$template"
            best_missing=("${missing[@]}")
        fi
    done

    {
        echo "BLOCKED: this issue body does not follow the repository's issue template."
        if [[ ${#templates[@]} -gt 1 ]]; then
            echo "Checked ${#templates[@]} templates under .github/ISSUE_TEMPLATE/; none matched."
        fi
        echo "Closest template: $best_template"
        echo
        echo "Missing required sections:"
        for line in "${best_missing[@]}"; do
            echo "  - $line"
        done
        echo
        echo "Re-run the SAME gh command with a --body that fills EVERY section below:"
        echo "-----8<----- ISSUE_TEMPLATE -----8<-----"
        cat "$best_template"
        echo "-----8<----------------------------------8<-----"
    } >&2
    exit 2
}

# Every *.md file directly under a repo's .github/ISSUE_TEMPLATE/, sorted for determinism. No
# personal fallback (unlike pr_template_guard.sh's find_template) — a repo with none is untouched.
find_issue_templates() {
    local root="$1"
    [[ -n "$root" && -d "$root/.github/ISSUE_TEMPLATE" ]] || return 0
    find "$root/.github/ISSUE_TEMPLATE" -maxdepth 1 -iname '*.md' 2>/dev/null | sort
}

# Strip a template's YAML frontmatter and HTML comment blocks, leaving only the structural
# markdown content the required-headers/checklist/lead-line rules read from.
strip_frontmatter_and_comments() {
    awk '
        NR==1 && $0=="---" { fm=1; next }
        fm==1 { if ($0=="---") fm=0; next }
        /<!--/ { incomment=1 }
        incomment==1 { if ($0 ~ /-->/) incomment=0; next }
        { print }
    ' "$1"
}

# True if $1 (a multi-line block of text) has a `##`/`###` header matching $2 (case-insensitive
# substring) whose section (up to the next such header, or EOF) contains a `- [ ]`/`- [x]` item.
section_has_checklist() {
    local text="$1" header_substr="$2" start_line next_line section
    start_line="$(grep -n -i -F -- "$header_substr" <<<"$text" | head -n1 | cut -d: -f1)"
    [[ -n "$start_line" ]] || return 1
    next_line="$(tail -n "+$((start_line + 1))" <<<"$text" | grep -n -E '^#{2,3}[[:space:]]' | head -n1 | cut -d: -f1)"
    if [[ -n "$next_line" ]]; then
        section="$(sed -n "$((start_line + 1)),$((start_line + next_line - 1))p" <<<"$text")"
    else
        section="$(sed -n "$((start_line + 1)),\$p" <<<"$text")"
    fi
    grep -Eq '^[[:space:]]*[-*][[:space:]]+\[[ xX]\]' <<<"$section"
}

# Populate the global `missing` array with every requirement of $1 (a template file) that $2 (the
# body) fails to satisfy, given $3 (newline-separated labels positively known on this command).
evaluate_template() {
    local template="$1" body="$2" labels="$3"
    local stripped first_tmpl_line first_body_line line header literal cond
    missing=()

    stripped="$(strip_frontmatter_and_comments "$template")"

    first_tmpl_line="$(grep -m1 -v '^[[:space:]]*$' <<<"$stripped")"
    if [[ -n "$first_tmpl_line" ]]; then
        first_body_line="$(grep -m1 -v '^[[:space:]]*$' <<<"$body")"
        if [[ "$first_tmpl_line" == '**'* && "$first_body_line" != '**'* ]]; then
            missing+=("a bold first line, like: $first_tmpl_line")
        fi
        if [[ "$first_tmpl_line" == *'·'* && "$first_body_line" != *'·'* ]]; then
            missing+=("a '·'-separated first line, like: $first_tmpl_line")
        fi
    fi

    while IFS= read -r line; do
        header="$(sed -E 's/^#+[[:space:]]*//; s/[[:space:]]+$//' <<<"$line")"
        [[ -n "$header" ]] || continue
        if ! grep -qiF -- "$header" <<<"$body"; then
            missing+=("$header")
            continue
        fi
        if section_has_checklist "$stripped" "$header" && ! section_has_checklist "$body" "$header"; then
            missing+=("$header (needs at least one - [ ] item)")
        fi
    done < <(grep -E '^#{2,3}[[:space:]]' <<<"$stripped")

    while IFS= read -r line; do
        [[ "$line" =~ issue-template-guard:[[:space:]]*require[[:space:]]+\"([^\"]+)\"([[:space:]]+if-label[[:space:]]+([^[:space:]]+))? ]] || continue
        literal="${BASH_REMATCH[1]}"
        cond="${BASH_REMATCH[3]:-}"
        if [[ -n "$cond" ]]; then
            grep -qxF -- "$cond" <<<"$labels" || continue   # label not positively known → fail open
        fi
        grep -qiF -- "$literal" <<<"$body" || missing+=("$literal")
    done < <(grep -E 'issue-template-guard:' "$template")
}

block_unresolved_repo() {
    # A verdict from a template we could not locate is "unknown", not "approved" — mirrors
    # pr_template_guard.sh's block_unresolved_repo. Must never share text with the "Missing
    # required sections" block: "I couldn't check" and "I checked and it's wrong" are different.
    local target="$1" tried="$2"
    {
        echo "BLOCKED: could not resolve the issue template for --repo $target."
        echo
        echo "This gh command targets a different repository than the session's cwd. Its local"
        echo "checkout was expected at $tried but was not found there, so this repo's"
        echo ".github/ISSUE_TEMPLATE/*.md could not be read."
        echo
        echo "This is NOT a verdict on the issue body — the template could not be located, so"
        echo "nothing was checked."
        echo
        echo "Clone the repo to $tried (or correct the --repo value), then re-run the SAME"
        echo "gh command."
    } >&2
    exit 2
}

block_unresolved_body_file() {
    # Same reasoning as pr_template_guard.sh's block_unresolved_body_file (dotfiles-linux-dev#78/#109):
    # a PreToolUse hook sees the command BEFORE shell expansion and sandboxed to the project
    # directory, so a generic "check the path" sends the author chasing a bug that isn't there.
    local path="$1" root="${2:-}"

    {
        echo "BLOCKED: the --body-file could not be read, so the issue body was never verified."
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
            echo "the repo (e.g. $root/.git/, which stays out of the worktree and any commit),"
            echo "then re-run the SAME gh command with the new path."
        else
            echo
            echo "If the file is created and consumed in the same command (e.g. \`cat >file &&"
            echo "gh issue create --body-file file\`), this hook still sees the pre-write state —"
            echo "write the file in a prior, separate step, then re-run this command. Otherwise"
            echo "check the path exists and is readable, then re-run the SAME gh command."
        fi
    } >&2
    exit 2
}

main "$@"
