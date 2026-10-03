#!/bin/bash
# PostToolUse (Bash matcher) hook: drive the two GitHub Projects v2 card transitions that Projects'
# own workflows CANNOT trigger — leaving the rest to the native automation.
#
#   git checkout -b / git switch -c  (a linked branch opened) -> card to "In progress"
#   gh pr create                     (the PR opened)          -> card to "In review"
#
# NOT handled here — on purpose: "PR merged / issue closed -> Done" is a built-in GitHub Projects
# workflow (issue.md already relies on it via `Closes #N`). Duplicating it in a hook would race the
# native automation, so Done is left native. This hook fills only the two gaps.
#
# Why a hook: the lifecycle transitions are deterministic functions of git/gh actions the harness
# already sees as Bash tool calls, but were being set by hand (`gh project item-edit`) every time —
# pure toil, easy to forget, board goes stale. Match the VERB, then resolve the issue/card via gh —
# never scrape a flag out of the raw command string (hook-command-string-scraping-fragile).
#
# Per-repo board ids (project number/node, Status field id, option ids) are discovered live via
# `gh project field-list` and cached in a LOCAL, git-ignored file — same seam as the tracker map:
# selecting a repo's board needs zero in-repo config, so a restricted repo is unaffected. A repo
# with no `<repo> kanban` project simply finds nothing and no-ops (which also skips Linear/none
# repos for free). A cached id gone stale (board recreated / columns renamed) self-heals: a failed
# move refreshes the cache once and retries.
#
# A CLOSED issue is a no-op (#131): a branch/PR that merely REFERENCES an already-closed issue
# (a follow-up ledger, a docs pass) must not drag its card backwards out of Done — Done is native
# (see above) and fires on the close EVENT, which already happened, so nothing re-corrects a wrong
# move afterwards. Checked via `gh issue view --json state` — the real invariant — not by having
# `card_item_id` also return the current column and refusing backward moves: that alternative
# reads right for the common case but is wrong for a legitimately REOPENED issue sitting in Done,
# which it would then refuse to ever move forward again. One more `gh` call per lifecycle verb is
# the honest cost of asking the actual question.
#
# Hook I/O contract: PostToolUse, so the tool already ran — this never blocks. It fails OPEN
# everywhere (no gh/jq, no repo, no board, no card, any gh error) by exiting 0 silently; on a
# successful move it emits an additionalContext note. Never exits non-zero.

set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0

# owner_repo/cache_file/discover_board/board_config/move_card live in the shared lib
# (dotfiles-dev#448) so this event hook and the reconcile that covers its misses
# (subagent_stop_sweep.sh) share one implementation instead of two copies drifting apart.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kanban_reconcile.sh
source "$HOOK_DIR/lib/kanban_reconcile.sh"

main() {
    local payload tool command target owner repo issue
    local project_number project_node status_field option_id item_id

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    target="$(target_column "$command")" || exit 0     # not a lifecycle verb → nothing to do

    read -r owner repo < <(owner_repo) || exit 0
    [[ -n "$owner" && -n "$repo" ]] || exit 0

    # issue.md names branches `<type>/<N>-<slug>`, so the branch carries the ref. `checkout -b`
    # checks the branch out, but `gh pr create --head <b>` may target a branch that is NOT HEAD
    # (dev-loop RESCUE opens PRs for other worktrees' branches from the main checkout) — then the
    # card to move is <b>'s, and HEAD is the wrong answer (#591).
    issue="$(issue_for_command "$command")" || exit 0
    [[ -n "$issue" ]] || exit 0

    [[ "$(issue_state "$owner" "$repo" "$issue")" != "CLOSED" ]] || exit 0

    read -r project_number project_node status_field option_id \
        < <(board_config "$owner" "$repo" "$target") || exit 0
    [[ "$project_number" == "AMBIGUOUS" ]] && { warn_ambiguous "$repo"; exit 0; }
    [[ -n "$project_number" && -n "$option_id" ]] || exit 0

    item_id="$(card_item_id "$project_number" "$owner" "$issue")" || exit 0
    [[ -n "$item_id" ]] || exit 0     # issue not on the board → nothing to move

    if ! move_card "$project_node" "$item_id" "$status_field" "$option_id"; then
        # A stale cache is the likely cause — refresh once and retry before giving up.
        rm -f "$(cache_file "$owner" "$repo")"
        read -r project_number project_node status_field option_id \
            < <(board_config "$owner" "$repo" "$target") || exit 0
        move_card "$project_node" "$item_id" "$status_field" "$option_id" || exit 0
    fi

    announce "$issue" "$target"
}

target_column() {
    # Map the Bash verb to its target column, or return 1 when it is neither lifecycle verb.
    local cmd="$1"
    if printf '%s' "$cmd" \
        | grep -Eq '^[[:space:]]*(rtk[[:space:]]+)?git[[:space:]]+(checkout[[:space:]]+.*-b|switch[[:space:]]+.*-c)'; then
        printf 'In progress'; return 0
    fi
    if printf '%s' "$cmd" \
        | grep -Eq '^[[:space:]]*(rtk[[:space:]]+)?gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
        printf 'In review'; return 0
    fi
    return 1
}

head_from_command() {
    # The branch named by `--head <b>`, `--head=<b>` or `-H <b>` on the `gh pr create` in $1, with
    # any `owner:` prefix stripped, read off the real argv so `--head x` quoted inside a --title
    # or --body is not mistaken for the flag. Returns 1 when the command carries no such flag, and
    # 2 when it cannot be tokenized (unbalanced quote), names `--head` with no value (gh rejects
    # it), or carries a value Bash expands before gh sees it (`$VAR`, `$(…)`, backticks, `{a,b}`)
    # — the caller must not guess a branch then: this hook reads the raw text, so a number inside
    # `"${BRANCH:-fix/564}"` is not the branch that was actually created.
    local json out
    json="$(printf '%s' "$1" \
        | python3 "$(dirname "${BASH_SOURCE[0]}")/lib/gh_cmd_match.py" pr 2>/dev/null)" || return 2
    out="$(jq -r 'if .head == null then "n" else "h" + .head end' <<<"$json" 2>/dev/null)" || return 2
    case "$out" in
        n) return 1 ;;
        h) return 2 ;;
        *'$'* | *'`'* | *'{'*) return 2 ;;
    esac
    out="${out#h}"
    printf '%s' "${out##*:}"
}

issue_for_command() {
    # Leftmost number run in the target branch name (feat/46-slug → 46), matching issue.md's
    # `<type>/<N>-<slug>` convention. The target is `--head`'s branch when the command names one,
    # else HEAD. An explicit `--head` with no number fails (never falls back to HEAD — that
    # fallback is the wrong-card bug).
    local branch rc=0
    branch="$(head_from_command "$1")" || rc=$?
    case "$rc" in
        0) ;;
        1) branch="$(git symbolic-ref --short HEAD 2>/dev/null)" || return 1 ;;
        *) return 1 ;;   # unparseable command: fail open, never guess a card
    esac
    [[ "$branch" =~ (^|[^0-9])([0-9]+)([^0-9]|$) ]] || return 1
    printf '%s' "${BASH_REMATCH[2]}"
}

issue_state() {
    # "OPEN"/"CLOSED" for issue <issue> in <owner>/<repo>, or empty on any gh error (fails open —
    # the caller's `!= "CLOSED"` then lets a state we could not resolve through, same as today).
    local owner="$1" repo="$2" issue="$3"
    gh issue view "$issue" --repo "$owner/$repo" --json state -q '.state' 2>/dev/null
}

card_item_id() {
    # Item id of the card whose content is issue <issue> on this board, or nothing.
    local num="$1" owner="$2" issue="$3"
    gh project item-list "$num" --owner "$owner" --format json --limit 500 2>/dev/null \
        | jq -r --argjson n "$issue" \
            'first(.items[] | select(.content.type=="Issue" and .content.number==$n) | .id) // empty' \
            2>/dev/null
}

announce() {
    jq -n --argjson n "$1" --arg col "$2" '{
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: ("kanban_lifecycle: moved issue #\($n)'"'"'s card to \"\($col)\".")
        }
    }' 2>/dev/null || true
}

warn_ambiguous() {
    jq -n --arg repo "$1" '{
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: ("kanban_lifecycle: more than one project is titled \"\($repo) kanban\" — did NOT move any card, to avoid touching the wrong board. Delete the duplicate(s) with `gh project delete <number> --owner <owner>`, then the card will move on the next action.")
        }
    }' 2>/dev/null || true
}

main "$@"
