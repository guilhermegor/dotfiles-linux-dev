#!/bin/bash
# PreToolUse (Bash matcher) hook: block a `git commit` whose staged changes look like they
# contain a secret — a known API-token format, a private-key header, an assignment of a quoted
# literal to a secret-named variable, or a real `.env` file being committed.
#
# Why this exists: a committed secret persists in git history even after it is deleted, and a
# push is effectively irreversible. The CLAUDE.md rule "never commit secrets" is only advisory;
# this hook makes it a harness-run pre-commit block.
#
# Hook I/O contract (same as commit_title_length_guard.sh): silent stdout, speaks only via exit
# code + stderr — no lib/common.sh / print_status. It fails OPEN: no jq, not a git repo, an
# empty/unreadable diff, or anything it cannot cleanly scan exits 0 and lets the commit proceed.
# Patterns are HIGH-SIGNAL on purpose — better to miss an exotic secret than to false-block a
# valid commit and train the user to disable the guard.
#
# ponytail: regex heuristics over the staged diff, not a real entropy/secret scanner — it will
# miss novel token formats and high-entropy blobs. Upgrade path: shell out to gitleaks or
# trufflehog if leaks slip through. The secret VALUE is never echoed (only file + category), so
# the block message can't itself leak it.

set -u

command -v jq >/dev/null 2>&1 || exit 0

# Shared with commit_title_length_guard.sh and commit_body_wrap.sh (dotfiles-linux-dev#324) — one
# `git commit` detection regex, not three that can drift apart.
# shellcheck source=lib/commit_command_matcher.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/commit_command_matcher.sh"

# Quote character classes built via printf so the patterns need no shell-quote gymnastics.
QUOTE="$(printf '[\x22\x27]')"      # a single or double quote
NOTQUOTE="$(printf '[^\x22\x27]')"  # any non-quote char

TOKEN_RE='(AKIA[0-9A-Z]{16}|gh[oprsu]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{22,}|xox[baprs]-[0-9A-Za-z-]{10,}|AIza[0-9A-Za-z_-]{35}|(sk|rk)_live_[0-9A-Za-z]{20,})'

# The PEM private-key marker is assembled from fragments so the full literal never appears
# contiguously in this file — otherwise this guard blocks its own commit (a secret scanner
# whose pattern file trips the scanner). Same reason the token regexes above are character
# classes, not sample tokens: never put a scannable literal in the scanner.
DASHES='-----'
PK_BEGIN="${DASHES}BEGIN "
PK_END="PRIVATE KEY${DASHES}"
SECRET_NAME='(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key)'
# A secret-named var assigned a quoted literal of >= 8 chars.
ASSIGN_RE="${SECRET_NAME}${QUOTE}?[[:space:]]*[:=][[:space:]]*${QUOTE}${NOTQUOTE}{8,}${QUOTE}"
# References/placeholders that are NOT real secrets — exclude to cut false positives.
PLACEHOLDER_RE='(process\.env|os\.environ|getenv|env\[|\$\{|\{\{|your[_-]|changeme|example|placeholder|redacted|dummy|xxxx|\.\.\.)'

# Run git against the repository the commit TARGETS, not this hook's cwd. `git -C ../other
# commit` stages into ../other, so an unqualified scan here would both miss that repo's secrets
# and block on unrelated staged content of our own. COMMIT_COMMAND_GIT_DIR is set by the matcher
# on a successful match, and is empty for the ordinary same-directory commit.
scan_git() {
    if [[ -n "$COMMIT_COMMAND_GIT_DIR" ]]; then
        git -C "$COMMIT_COMMAND_GIT_DIR" "$@"
    else
        git "$@"
    fi
}

main() {
    local payload tool command scan_target diff names env_hit hit

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    # Only act on an actual `git commit`. Every accepted spelling — and the per-segment anchor
    # that keeps a mere *mention* of "git commit" from tripping this — lives in the shared
    # matcher; see its header for the four shapes the old inline regex missed.
    command_has_git_commit "$command" || exit 0

    scan_git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

    # `git commit -a`/`--all` also commits tracked-but-unstaged changes, which are not in
    # `git diff --cached`. Detect the flag and widen the scan to `git diff HEAD` in that case.
    # Missing the flag only ever scans a subset (--cached) — a safe, fail-open miss.
    scan_target="cached"
    if printf '%s' "$command" | grep -Eq '(^|[[:space:]])(--all|-[A-Za-z]*a[A-Za-z]*)([[:space:]]|$)'; then
        scan_target="all"
    fi

    if [[ "$scan_target" == "all" ]]; then
        diff="$(scan_git diff HEAD --no-color 2>/dev/null)" || exit 0
        names="$(scan_git diff HEAD --name-only 2>/dev/null)"
    else
        diff="$(scan_git diff --cached --no-color 2>/dev/null)" || exit 0
        names="$(scan_git diff --cached --name-only 2>/dev/null)"
    fi

    # A real .env file being committed (.env.example / .sample / .template are fine).
    env_hit="$(printf '%s\n' "$names" \
        | grep -E '(^|/)\.env(\.[[:alnum:]_]+)?$' \
        | grep -Eiv '\.(example|sample|template|dist|md|txt)$' \
        | head -1)"
    if [[ -n "$env_hit" ]]; then
        block "$env_hit" "an environment file (.env) — these hold secrets and belong in .gitignore"
    fi

    hit="$(scan_added_lines "$diff")"
    [[ -n "$hit" ]] || exit 0
    block "${hit%%$'\t'*}" "${hit#*$'\t'}"
}

# Echo "<file>\t<category>" for the first secret-looking added line, or nothing.
scan_added_lines() {
    local file="" line content low
    while IFS= read -r line; do
        case "$line" in
            '+++ '*) file="${line#+++ b/}" ;;
            '+'*)
                content="${line#+}"
                if [[ "$content" == *"$PK_BEGIN"*"$PK_END"* ]]; then
                    printf '%s\t%s\n' "$file" "a private key"; return
                fi
                if [[ "$content" =~ $TOKEN_RE ]]; then
                    printf '%s\t%s\n' "$file" "an API token / access key"; return
                fi
                low="${content,,}"
                if [[ "$low" =~ $ASSIGN_RE ]] && ! [[ "$low" =~ $PLACEHOLDER_RE ]]; then
                    printf '%s\t%s\n' "$file" "a hardcoded secret assignment"; return
                fi
                ;;
        esac
    done <<< "$1"
}

block() {
    local file="$1" kind="$2"
    {
        echo "BLOCKED: the staged changes appear to contain a secret."
        echo
        echo "  File:     ${file:-<unknown>}"
        echo "  Detected: ${kind}"
        echo
        echo "A committed secret persists in git history even after it is removed, and a push is"
        echo "effectively irreversible. Move the value to an environment variable or a git-ignored"
        echo ".env file, unstage it from the commit, then re-run the commit."
        echo
        echo "If this is a genuine false positive (a test fixture or placeholder), run the commit"
        echo "yourself outside this guard — type it in the prompt with a leading '! ' — or refine"
        echo "the patterns in commit_secret_guard.sh."
    } >&2
    exit 2
}

main "$@"
