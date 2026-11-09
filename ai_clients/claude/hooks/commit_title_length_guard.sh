#!/bin/bash
# PreToolUse (Bash matcher) hook: block a `git commit` whose inline title line exceeds the repo's
# gitlint title-max-length (read from .gitlint, default 72) BEFORE the pre-commit gate runs.
#
# Why this exists: gitlint's T1 rule fails at the commit-msg stage, which runs AFTER the whole
# pre-commit gate (tests + coverage). On a slow gate (~15 min in some repos) a too-long title
# silently wastes an entire run before the failure surfaces. A memory note ("keep titles <= 72")
# cannot enforce this — nothing runs it before the gate. This hook is harness-run, so it turns a
# post-gate failure into an instant pre-gate block.
#
# Hook I/O contract (same as pr_template_guard.sh): silent on stdout, speaks only through exit code
# + stderr — so there is intentionally no lib/common.sh / print_status here. It fails OPEN
# everywhere: any message the guard cannot cleanly parse out of the raw command string (a heredoc
# not feeding `-F-`, `-F path/to/file`, or a title built from shell expansion) exits 0 and lets the
# commit proceed. Per the hook-command-string-scraping-fragile lesson, better to miss some long
# titles than to false-block a valid commit.
#
# Since #961 the guard also measures the FIRST -m of a multi-`-m` commit, a `-am` cluster, and every
# commit inside a readable `bash|sh <file>.sh` (see lib/commit_command_matcher.sh); an unreadable
# script or an unparseable message still fails open.
#
# One narrowed exception (issue #140): `-F-`/`--file=-` fed by exactly one heredoc is the most
# common shape an agent session uses, and unlike `-F path`, the heredoc body IS present in the
# raw command string — so extract_heredoc_title() measures its first line instead of stepping
# over it.

set -u

# jq parses the hook payload; without it we cannot inspect the command, so fail open.
command -v jq >/dev/null 2>&1 || exit 0

# Shared with commit_body_wrap.sh and commit_secret_guard.sh (dotfiles-linux-dev#324) — one
# `git commit` detection regex, not three that can drift apart.
# shellcheck source=lib/commit_command_matcher.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/commit_command_matcher.sh"

DEFAULT_TITLE_MAX_LENGTH=72

main() {
    local payload tool command title max_len set idx
    local -a titles dirs

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    # A `bash|sh <file>.sh` command runs its commits out of sight of the payload (#961): append the
    # script's text so the matcher and the title extraction below see the commits inside it.
    command="$(commit_expand_script "$command")"

    # Only act on an actual `git commit`. Every accepted spelling — and the per-segment anchor
    # that keeps a mere *mention* of "git commit" from tripping this — lives in the shared
    # matcher; see its header for the four shapes the old inline regex missed.
    command_has_git_commit "$command" || exit 0

    titles=()
    dirs=()
    if printf '%s' "$command" | grep -q '<<' && title="$(extract_heredoc_title "$command")"; then
        # `-F-`/`--file=-` fed by exactly one heredoc (issue #140): its body is in the raw string.
        # The title belongs to the commit that reads stdin, so its limit comes from THAT commit's
        # `git -C` directory; if that commit cannot be identified, skip rather than guess.
        commit_source_dir "$command" stdin
        if ((COMMIT_SOURCE_FOUND && ! COMMIT_SOURCE_HAS_M)); then
            titles+=("$title")
            dirs+=("$COMMIT_SOURCE_DIR")
        fi
    fi
    # Inline `-m`: the title is the FIRST -m of each commit, however many follow (#961). Checked
    # independently of a heredoc title, so a script mixing both is measured in full. `-F <path>`
    # commits carry no inline message, so they yield nothing and pass.
    commit_inline_messages "$command"
    idx=0
    for set in ${COMMIT_MESSAGE_SETS[@]+"${COMMIT_MESSAGE_SETS[@]}"}; do
        title="${set%%"$_MSG_SEP"*}"
        titles+=("${title%%$'\n'*}")   # first line only
        dirs+=("${COMMIT_MESSAGE_DIRS[idx]}")
        idx=$((idx + 1))
    done

    idx=0
    for title in ${titles[@]+"${titles[@]}"}; do
        # Each title is judged against ITS commit's repository (`git -C <dir>`), not the cwd's.
        max_len="$(read_title_max_length "${dirs[idx]}")"
        idx=$((idx + 1))
        (( ${#title} > max_len )) && block_title "$title" "$max_len"
    done
    exit 0
}

block_title() {
    local title="$1" max_len="$2"
    {
        echo "BLOCKED: commit title is ${#title} characters; the limit is ${max_len} (gitlint T1 / title-max-length)."
        echo
        echo "  Title: ${title}"
        echo
        echo "gitlint's T1 fails at the commit-msg stage, which runs AFTER the full pre-commit gate"
        echo "(tests + coverage) — this title would waste that entire run before the error surfaces."
        echo "Shorten the title to <= ${max_len} characters and re-run the SAME commit."
    } >&2
    exit 2
}

extract_heredoc_title() {
    # Narrow, unambiguous case from issue #140: `-F-`/`--file=-` (message read from stdin) fed
    # by a single heredoc. The heredoc body IS the message and IS present in the raw command
    # string, so its first line is the title. Return 1 (fail open) on anything this static
    # scrape cannot resolve without a real shell parse: no `-F-`, more than one heredoc marker,
    # an `-m`/`--message` also present (ambiguous source), or a title needing shell expansion
    # (`$...`, `` `...` ``) that a raw-string measurement would get wrong.
    local s="$1" opener_re body_re count title

    printf '%s' "$s" \
        | grep -Eq -- '(^|[[:space:]])(-F[[:space:]]*-|--file([[:space:]]+|=)-)([[:space:]]|$)' \
        || return 1
    # An `-m` on the SAME commit as the `-F-` is ambiguous; the caller checks that per commit
    # (COMMIT_SOURCE_HAS_M), since an `-m` on another commit of a script is irrelevant.

    opener_re=$'<<-?[[:space:]]*[\'"]?[^[:space:]\'"<>|&;()]+[\'"]?'
    count="$(printf '%s' "$s" | grep -oE "$opener_re" | wc -l)"
    [[ "$count" -eq 1 ]] || return 1

    body_re="${opener_re}"$'[^\n]*\n(.*)'
    [[ "$s" =~ $body_re ]] || return 1
    title="${BASH_REMATCH[1]%%$'\n'*}"

    case "$title" in
        *'$'* | *'`'*) return 1 ;;
    esac

    printf '%s' "$title"
}

read_title_max_length() {
    # Echo the repo's gitlint title-max-length, or the default when absent/unparseable. The option
    # name `line-length` is shared with [body-max-line-length], so it MUST be read only inside the
    # [title-max-length] section.
    local root gitlint val dir="${1:-}"
    if [[ -n "$dir" ]]; then
        root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
    else
        root="$(git rev-parse --show-toplevel 2>/dev/null)"
    fi
    gitlint="$root/.gitlint"
    if [[ -n "$root" && -r "$gitlint" ]]; then
        val="$(awk '
            /^\[/ { in_section = ($0 ~ /^\[title-max-length\]/) }
            in_section && /^[[:space:]]*line-length[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]/, ""); print; exit
            }' "$gitlint" 2>/dev/null)"
        [[ "$val" =~ ^[0-9]+$ ]] && { printf '%s' "$val"; return 0; }
    fi
    printf '%s' "$DEFAULT_TITLE_MAX_LENGTH"
}

main "$@"
