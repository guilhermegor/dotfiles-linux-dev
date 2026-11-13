#!/bin/bash
# PreToolUse (Bash matcher) hook: enforce a repo's ISSUE_TEMPLATE(s) on `gh issue create` /
# `gh issue edit` — the same mechanism pr_template_guard.sh already applies to PR bodies, aimed at
# .github/ISSUE_TEMPLATE/*.md instead of .github/PULL_REQUEST_TEMPLATE.md.
#
# Also judges the REST twin (dotfiles-linux-dev#714): `gh api repos/O/R/issues -X POST` (create) and
# `gh api repos/O/R/issues/N -X PATCH|PUT` (edit), incl. the implicit POST when a -f/-F/--input
# is given with no -X. The body comes from a `body=` field, `-F body=@file`, or `--input` JSON;
# a REST create with no body counts as an EMPTY body (REST has no editor mode). Found by the
# same real-argv tokenizer (`gh_cmd_match.py api-issue`), never a raw-string regex.
# A path with an unexpanded shell variable fails CLOSED (judged as an unknown write), EXCEPT when
# the variable sits only in the owner/repo segment and the literal resource after it is not
# `issues` (dotfiles-linux-dev#822): `repos/$R/pulls/816/merge` is judged like its literal twin
# and passes. A variable in the resource segment itself, or any `issues` resource, stays closed.
# The same holds for a loop id after a literal resource (dotfiles-linux-dev#870):
# `for n in 27 29; do sha=$(gh api repos/o/r/pulls/$n --jq .head.sha); gh api -X PUT
# repos/o/r/pulls/$n/merge -f sha=$sha; done` is a pulls write, not an issue write. A command
# right after a shell keyword (`do`/`then`/`else`/`if`/`elif`/`while`/`until`/`coproc`) is judged too, so a real `issues -X POST` in that loop stays blocked.
#
# Fails CLOSED when a shell runs text the hook cannot read AND the command is about a gh issue
# write (dotfiles-linux-dev#937): `eval "$Q"` / `bash -c "$Q"` of a bare variable, a shell fed on
# stdin (`... | bash`, `bash <<EOF`, `bash < f`), a variable command word (`$GH api graphql`).
# The trigger is the whole command also naming `gh` plus an issue/graphql/api word, so
# `eval "$(ssh-agent)"` or `curl u | bash` alone still pass.
# ACCEPTED CEILINGS (documented, not fixable by a PreToolUse hook): (1) the read race — the hook
# reads an `@file` before `gh` does, and anything that rewrites it in between is invisible; the
# hook sees one command string and cannot lock a file, and a writer in the same chain is already
# handled by chain_moves_files, so only a concurrent process remains. (2) `eval "$(cmd)"` and
# `bash script.sh` hide the text behind a command's output or a file. (3) GraphQL `transferIssue`
# moves an existing issue (no body in its input) so it is not a create; the creating mutations
# are listed, with their schema source, at GRAPHQL_CREATING in lib/gh_cmd_match.py.
#
# Generic and data-driven: a target repo with no issue template is untouched (exit 0). `/issue`
# (ai_clients/claude/commands/issue.md) builds its body from the target repo's templates when
# they exist, and falls back to its own What / Why / Scope / Documentation skeleton only when
# they do not (dotfiles-linux-dev#853). Nothing here names a specific repo or template.
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
# A missing helper (partial deploy) must not read as "every body is compliant": without
# evaluate_template nothing is checked. This runs on EVERY Bash call, so only a matched issue
# write is refused (below), never unrelated commands.
SPEC_LIB_OK=1
# shellcheck source=lib/issue_spec_complete.sh
source "$SCRIPT_DIR/lib/issue_spec_complete.sh" 2>/dev/null || SPEC_LIB_OK=0

# Fail open if jq (used to parse the hook payload) is unavailable.
command -v jq >/dev/null 2>&1 || exit 0

main() {
    local payload tool command root body_source labels
    local -a json_labels=()
    local -a templates=() best_missing=() missing=()
    local template best_template="" best_count=-1

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    # Relative paths in the command (`@q.graphql`) resolve against the Bash tool's cwd, which the
    # payload names; the hook's own cwd may differ, so judge the file gh will actually read.
    local payload_cwd
    payload_cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
    if [[ -n "$payload_cwd" && -d "$payload_cwd" ]]; then
        cd "$payload_cwd" || return 1
    fi

    # Find a `[rtk] gh issue create|edit` invocation by real argv, not by scanning raw text —
    # mirrors pr_template_guard.sh's resolve_gh_command call exactly (see its comment for the
    # bypasses a start-anchored regex missed: chained after `;`/`&&`/`||`/`|`/`&`/a newline, or
    # fooled by flag-shaped text inside an unrelated quoted argument).
    # Both command forms are judged INDEPENDENTLY (dotfiles-linux-dev#714): one command string can
    # carry a state-only REST edit AND a `gh issue create`, and either may be the bad one. The
    # script re-invokes itself once per noun (ITG_NOUN) and any exit 2 wins.
    if [[ -z "${ITG_NOUN:-}" ]]; then
        local noun rc
        for noun in api-issue issue; do
            rc=0
            printf '%s' "$payload" | ITG_NOUN="$noun" bash "${BASH_SOURCE[0]}" || rc=$?
            [[ $rc -eq 2 ]] && exit 2
        done
        exit 0
    fi
    # `gh api repos/O/R/issues -X POST|PATCH ...` creates/edits an issue without passing
    # `gh issue`; text that looks like one but cannot be tokenized is refused, not allowed.
    resolve_gh_command "$command" "$ITG_NOUN" || exit 0   # unparseable -> unknown (gh issue)
    [[ "$GH_MATCHED" == "true" ]] || exit 0
    if [[ "$GH_UNPARSEABLE" == "true" ]]; then
        echo "BLOCKED: this command looks like a REST write to .../issues but could not be parsed" >&2
        echo "(unbalanced quote or unterminated heredoc), so its body was never verified." >&2
        echo "Re-run it as a plain, tokenizable \`gh api repos/O/R/issues ...\` command." >&2
        exit 2
    fi
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
    # Only now: a missing lib must not block a repo that has nothing to enforce.
    if [[ "$SPEC_LIB_OK" != 1 ]]; then
        echo "BLOCKED: issue_spec_complete.sh is missing next to issue_template_guard.sh, so this" >&2
        echo "issue body cannot be verified. Re-run \`make ai_clients\` to deploy hooks/lib/ in full." >&2
        exit 2
    fi

    if [[ "$GH_HAS_BODY_FILE" == "true" ]]; then
        if [[ -r "$GH_BODY_FILE" ]]; then
            if [[ "$GH_BODY_FILE_JSON" == "true" ]]; then
                # `gh api --input`: a JSON payload, the body is its `.body` member.
                body_source="$(jq -r '.body // ""' "$GH_BODY_FILE" 2>/dev/null)" \
                    || block_unresolved_body_file "$GH_BODY_FILE" "$root"
                # The payload's own labels count as positively known labels too.
                mapfile -t json_labels < <(jq -r '.labels[]? | if type == "object" then .name else . end' \
                    "$GH_BODY_FILE" 2>/dev/null)
                GH_LABELS+=("${json_labels[@]}")
            else
                body_source="$(cat "$GH_BODY_FILE")"
            fi
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

    if [[ "$path" == "-" ]]; then
        # The matcher's blind marker (stdin, a second write in the chain, a shell-built argument):
        # no --body-file was passed, so naming one would send the author chasing nothing (#987).
        {
            echo "BLOCKED: the issue body could not be read from this command, so it was never verified."
            echo
            echo "No --body-file was passed. The body comes from stdin, or the command builds part of"
            echo "its own arguments (a shell variable, a glob, a command substitution), or it chains"
            echo "several issue writes. Re-run each write as its own plain \`gh\` command with the"
            echo "body written out literally."
        } >&2
        exit 2
    fi

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
