#!/bin/bash
# PreToolUse (Bash matcher) hook: block `git checkout -b` / `git switch -c` when the new branch
# does not trace back to a tracked issue, and point the author at /issue.
#
# Why this exists: the house rule is "an issue (and a kanban card) exists BEFORE any
# implementation" — it is what keeps the backlog the plan of record, the PR's closing link honest,
# and the board moving on its own. Today that rule is enforced only by remembering to run /issue
# first, and the moment a branch is cut without one, the card, the close link and the release notes
# all silently lose the trace. Prose is advisory; a PreToolUse guard is binding.
#
# Branch creation is the right interception point: it is the first observable tool call of any
# implementation. Its sibling — protected_branch_guard.sh — catches the other end of the same
# mistake (work committed straight onto main, where no branch was ever cut). Deliberately NOT a
# Write/Edit guard: gating file edits would fire on scratchpads, notes and read-modify
# exploration, which is user-hostile.
#
# Tracker-agnostic. The tracker is resolved PER REPO from a LOCAL, git-ignored map
# (~/.claude/issue-trackers.conf) so a repo you have restricted rights on — e.g. one hosted on
# GitHub but tracking issues in Linear — needs ZERO in-repo files to select its tracker. Supported:
#   * github — verified via `gh` (always authenticated in this setup);
#   * linear — a structural ref check (branch carries a TEAM-123 id), upgraded to a real existence
#     lookup ONLY when LINEAR_API_KEY is set. A PreToolUse hook is a standalone bash process and
#     CANNOT reach the Linear MCP server (MCP is a Claude-side client, absent here), so the token +
#     GraphQL API is the only automated Linear existence path — and it is optional;
#   * none — guard off for this repo.
#
# Decision, once a tracker and a branch ref are known:
#   * no ref in the branch name              -> BLOCK (nothing to trace)
#   * tracker says the issue EXISTS          -> allow
#   * tracker AUTHORITATIVELY says NOT FOUND -> BLOCK (a phantom closing link)
#   * tracker cannot answer (no creds / net) -> allow (unknown != absent)
#
# Hook I/O contract (same as the other guards): silent on stdout, speaks through exit code +
# stderr, no lib/common.sh. It fails OPEN — not a git repo, tracker "none", or any answer the
# tracker cannot give confidently exits 0 and lets the branch be created.

set -u

command -v jq >/dev/null 2>&1 || exit 0

# Prefixing the command with this makes the guard stand aside, for a genuine throwaway branch:
#   ALLOW_UNTRACKED_BRANCH=1 git checkout -b scratch/poke-at-it
ESCAPE_HATCH='ALLOW_UNTRACKED_BRANCH=1'

# Local, git-ignored, OUTSIDE any project repo: selecting a repo's tracker never edits the repo.
# Lines: "<origin-url-or-dir-name substring>  <github|linear|none>". First match wins. The file
# documents its own format in a header comment; a missing file just means "auto-detect".
TRACKER_MAP="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/issue-trackers.conf"

main() {
    local payload tool command branch tracker ref status

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    [[ "$command" == *"$ESCAPE_HATCH"* ]] && exit 0

    branch="$(extract_new_branch "$command")" || exit 0   # not a branch-creating command
    [[ -n "$branch" ]] || exit 0

    tracker="$(resolve_tracker)"
    [[ "$tracker" == "none" ]] && exit 0      # no board for this repo → nothing to enforce

    # A GitHub-tracked repo whose branch carries a FOREIGN tracker id (Linear hm-848, Jira ABC-12)
    # cannot be verified against GitHub — the id's digits are not an issue number. Fail OPEN rather
    # than misreading them and blocking on a phantom GitHub issue (dotfiles-linux-dev#77). The right
    # long-term fix for such a repo is naming its real tracker in issue-trackers.conf; until then,
    # do not false-block. (Linear/none trackers handle their own ids and never reach here.)
    if [[ "$tracker" == "github" ]] && carries_foreign_tracker_id "$branch"; then
        exit 0
    fi

    ref="$(ref_in_branch "$tracker" "$branch")"
    [[ -n "$ref" ]] || block_no_ref "$branch" "$tracker"

    status="$(issue_status "$tracker" "$ref")"
    case "$status" in
        exists | unknown) exit 0 ;;                     # verified, or cannot verify → allow
        absent) block_absent "$branch" "$ref" "$tracker" ;;
        *) exit 0 ;;                                     # defensive: unknown state → allow
    esac
}

strip_heredoc_bodies() {
    # Drop heredoc bodies so a git verb written inside one (an issue/PR body) is not read as a
    # command. Copy of the helper in protected_branch_guard.sh — hooks are intentionally
    # self-contained (like the jq payload boilerplate every guard repeats); keep the two in sync.
    local line delim="" trimmed in_body=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( in_body )); then
            trimmed="${line#"${line%%[!$'\t']*}"}"
            [[ "$trimmed" == "$delim" ]] && in_body=0
            continue
        fi
        if [[ "$line" =~ \<\<-?[[:space:]]*[\"\'\\]?([[:alnum:]_]+) ]]; then
            delim="${BASH_REMATCH[1]}"
            in_body=1
        fi
        printf '%s\n' "$line"
    done
}

segment_commands() {
    # One shell command segment per line: break on && || ; | and existing newlines, so the branch
    # regex below can anchor to a segment START and never span two commands.
    sed -E 's/(\|\||&&|[;|])/\n/g'
}

extract_new_branch() {
    # Emit the branch name from `git checkout -b|-B <name>` / `git switch -c|-C <name>`, or return 1
    # when the command creates no branch. Match per COMMAND SEGMENT, each anchored to the segment
    # start, so an unrelated `-c` in a chained/piped command (`grep -c 'labels:'`) and a git verb
    # mentioned inside a heredoc body are never mistaken for a branch creation (issue #54).
    # ponytail: a regex over segments, not a full shell parse — a name built from shell expansion is
    # rejected below and fails open (the safe miss). Residual: a git verb inside a multi-line QUOTED
    # string (not a heredoc) can still be its own segment; add a quote-aware splitter only if it bites.
    local cmd seg val re
    cmd="$(printf '%s\n' "$1" | strip_heredoc_bodies)"
    re='^(rtk[[:space:]]+)?git[[:space:]]+(checkout|switch)([[:space:]]+[^[:space:]]+)*[[:space:]]+(-b|-B|-c|-C)[[:space:]]+("[^"]*"|'\''[^'\'']*'\''|[^[:space:]]+)'

    while IFS= read -r seg || [[ -n "$seg" ]]; do
        seg="${seg#"${seg%%[![:space:]]*}"}"      # ltrim so the regex anchor sees the command start
        [[ "$seg" =~ $re ]] || continue

        val="${BASH_REMATCH[5]}"
        val="${val#[\"\']}"
        val="${val%[\"\']}"
        case "$val" in
            *'$'* | *'`'*) continue ;;            # dynamic name — cannot resolve statically
        esac

        printf '%s' "$val"
        return 0
    done < <(printf '%s' "$cmd" | segment_commands)

    return 1
}

resolve_tracker() {
    # Emit github | linear | none for the current repo. Order: env override, then the local
    # git-ignored map, then auto-detect (a GitHub remote → github, else none — there is no remote
    # signal for Linear, so a GitHub-hosted / Linear-tracked repo MUST name itself in the map).
    local override url root name key val
    override="${CLAUDE_ISSUE_TRACKER:-}"
    [[ -n "$override" ]] && { printf '%s' "$override"; return; }

    root="$(git rev-parse --show-toplevel 2>/dev/null)" || { printf 'none'; return; }
    url="$(git remote get-url origin 2>/dev/null || true)"
    name="$(basename "$root")"

    if [[ -r "$TRACKER_MAP" ]]; then
        while read -r key val _; do
            [[ -z "$key" || "$key" == \#* ]] && continue
            if [[ -n "$url" && "$url" == *"$key"* ]] || [[ "$name" == "$key" ]]; then
                printf '%s' "$val"
                return
            fi
        done < "$TRACKER_MAP"
    fi

    [[ "$url" == *github.com* ]] && { printf 'github'; return; }
    printf 'none'
}

ref_in_branch() {
    local tracker="$1" branch="$2"
    case "$tracker" in
        github) github_ref_in "$branch" ;;
        linear) linear_ref_in "$branch" ;;
    esac
}

carries_foreign_tracker_id() {
    # True when the branch's LEADING slug token is a well-formed foreign tracker id —
    # <letters>-<digits> (Linear hm-848, Jira ABC-12). Leading position is what separates a
    # foreign id (hm-848-desc) from a GitHub number (42-desc) and from a trailing kebab number
    # (short-desc-42), for which github_ref_in still finds the real issue number. `##*/` drops any
    # type/ prefix (feat/, fix/), so feature/hm-848-x -> hm-848-x.
    #
    # Used only in github mode: such an id's digits are a Linear/Jira number, NOT a GitHub issue
    # number, so extracting them and calling `gh issue view` false-blocks on a phantom issue
    # (dotfiles-linux-dev#77). A hook cannot reach Linear, so the id is UNKNOWN -> fail OPEN.
    # ponytail: irreducible collision with a real word-number leading slug (oauth-2-x reads as
    # foreign and is allowed) — accepted, because fail-open is this guard's declared safe direction
    # ("better to miss than to false-block"); the alternative (false-close) is the bug being fixed.
    local slug="${1##*/}"
    [[ "$slug" =~ ^[A-Za-z]+-[0-9]+([-_.]|$) ]]
}

github_ref_in() {
    # Emit the issue number carried by the branch name, if any. Covers the shapes /issue produces
    # and the ones people type by hand: feat/short-desc-42, 42-short-desc, fix/42-short-desc.
    local branch="$1"
    [[ "$branch" =~ (^|[^0-9])([0-9]+)([^0-9]|$) ]] || return 0
    printf '%s' "${BASH_REMATCH[2]}"
}

linear_ref_in() {
    # Emit "<TEAMKEY> <number>" for a Linear-style ref in the branch (dit-456 → "DIT 456"), or
    # nothing. The `type/` prefix convention (feat/, fix/) shields against matching the prefix,
    # which is followed by `/`, not `-<digit>`.
    local branch="$1"
    [[ "$branch" =~ ([A-Za-z][A-Za-z0-9]*)-([0-9]+) ]] || return 0
    printf '%s %s' "${BASH_REMATCH[1]^^}" "${BASH_REMATCH[2]}"
}

issue_status() {
    # Tri-state: exists | absent | unknown. "unknown" must never block (unknown != absent).
    local tracker="$1" ref="$2"
    case "$tracker" in
        github) github_status "$ref" ;;
        linear) linear_status "$ref" ;;
        *) printf 'unknown' ;;
    esac
}

github_status() {
    local number="$1" out rc
    command -v gh >/dev/null 2>&1 || { printf 'unknown'; return; }

    out="$(gh issue view "$number" --json number 2>&1)"
    rc=$?
    (( rc == 0 )) && { printf 'exists'; return; }

    # Only an authoritative "no such issue" is absent; any other gh failure (offline,
    # unauthenticated, rate-limited) is unknown.
    printf '%s' "$out" | grep -qiE 'could not resolve|not found|no issues? found' \
        && { printf 'absent'; return; }
    printf 'unknown'
}

linear_status() {
    # Structural refs are all we can confirm without a token, so no key → unknown (the branch
    # carried a ref; we simply cannot verify it, and unknown fails open). With a token, ask the
    # GraphQL API: a 200 with an empty node set is an authoritative not-found.
    local ref="$1" team num body resp nodes
    [[ -n "${LINEAR_API_KEY:-}" ]] || { printf 'unknown'; return; }
    command -v curl >/dev/null 2>&1 || { printf 'unknown'; return; }

    team="${ref%% *}"
    num="${ref##* }"
    body="$(jq -n --arg k "$team" --argjson n "$num" \
        '{query:"query($k:String!,$n:Float!){issues(filter:{team:{key:{eq:$k}},number:{eq:$n}}){nodes{identifier}}}",variables:{k:$k,n:$n}}' \
        2>/dev/null)" || { printf 'unknown'; return; }

    resp="$(curl -sS --max-time 8 -X POST https://api.linear.app/graphql \
        -H "Authorization: $LINEAR_API_KEY" -H 'Content-Type: application/json' \
        --data "$body" 2>/dev/null)" || { printf 'unknown'; return; }

    # Any GraphQL error means we did not get an authoritative answer.
    printf '%s' "$resp" | jq -e '.errors' >/dev/null 2>&1 && { printf 'unknown'; return; }
    nodes="$(printf '%s' "$resp" | jq -r '.data.issues.nodes | length' 2>/dev/null)" \
        || { printf 'unknown'; return; }

    (( nodes > 0 )) && { printf 'exists'; return; }
    printf 'absent'
}

block_no_ref() {
    local branch="$1" tracker="$2"
    {
        echo "BLOCKED: branch '${branch}' carries no tracked-issue reference."
        echo
        case "$tracker" in
            github) echo "Expected an issue number in the name (feat/thing-123, 123-thing)." ;;
            linear) echo "Expected a Linear issue id in the name (feat/dit-456-thing)." ;;
        esac
        echo
        echo "Every implementation starts from an issue on the board — that keeps the backlog the"
        echo "plan of record, the PR's closing link honest, and the kanban card moving."
        echo
        echo "Run /issue to open one, or re-run with:  ${ESCAPE_HATCH} <your command>"
    } >&2
    exit 2
}

block_absent() {
    local branch="$1" ref="$2" tracker="$3" pretty
    case "$tracker" in
        github) pretty="#${ref}" ;;
        linear) pretty="${ref% *}-${ref#* }" ;;   # "DIT 456" → "DIT-456"
        *) pretty="$ref" ;;
    esac
    {
        echo "BLOCKED: branch '${branch}' cites ${pretty}, but the tracker has no such issue."
        echo
        echo "A branch that closes a phantom issue produces a dead closing link and an untracked"
        echo "change. Point it at a real issue, run /issue to create one, or re-run with:"
        echo
        echo "  ${ESCAPE_HATCH} <your command>"
    } >&2
    exit 2
}

main "$@"
