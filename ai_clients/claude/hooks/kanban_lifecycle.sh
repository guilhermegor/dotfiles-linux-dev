#!/bin/bash
# PostToolUse (Bash matcher) hook: drive the two GitHub Projects v2 card transitions that Projects'
# own workflows CANNOT trigger — leaving the rest to the native automation.
#
#   git checkout -b / git switch -c  (a linked branch opened) -> card to "In progress"
#   gh pr create                     (the PR opened)          -> card to "In review"
#   gh api repos/<o>/<r>/pulls -f head=<b>  (the REST twin, #859) -> card to "In review"
#   gh api repos/<o>/<r>/pulls --input <f>  (head read from the JSON file, #900) -> "In review"
#
# Each verb is recognised as any segment of a compound command, and a literal `cd <path>` before it
# decides where the repo and branch resolve (#900): `cd <worktree> && gh pr create` is the normal
# shape for an agent in a worktree. The first verb in the command wins. A `cd` the hook cannot
# resolve (`$VAR`, flags, no argument) stops the scan, so nothing moves rather than the wrong card.
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
#
# One exception to "silent": when the board READ or WRITE itself fails (the board is GraphQL-backed,
# so the same rate limit that sends an agent to the REST PR fallback also stops the move), it
# emits a warning naming the issue, the board and the target column (#859). "No board" and "issue
# not on the board" stay silent — only a gh failure is worth telling the session about
# (board_config returns 3 for no-board, 1 for a gh failure — #865).

set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0

# owner_repo/cache_file/discover_board/board_config/move_card live in the shared lib
# (dotfiles-linux-dev#448) so this event hook and the reconcile that covers its misses
# (subagent_stop_sweep.sh) share one implementation instead of two copies drifting apart.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kanban_reconcile.sh
source "$HOOK_DIR/lib/kanban_reconcile.sh"

main() {
    local payload payload_cwd tool command segment cd_path target owner repo issue rest rest_head
    local project_number project_node status_field option_id item_id

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    # The hook's own cwd is not the Bash tool's: a relative `cd` or `--input` must resolve from the
    # payload's (#902 review). A payload without one keeps the hook's cwd.
    payload_cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
    if [[ -n "$payload_cwd" ]]; then cd "$payload_cwd" 2>/dev/null || exit 0; fi

    select_lifecycle_segment "$command" || exit 0      # no lifecycle verb → nothing to do
    command="$segment"
    if [[ -n "$cd_path" ]]; then cd "$cd_path" 2>/dev/null || exit 0; fi

    # A REST-opened PR names its repo in the URL path and its branch in the `head=` field, so
    # neither cwd nor HEAD is consulted (#859); everything else resolves from cwd as before.
    # Only for the PR-open verb, so a `checkout -b ; gh api …/pulls` compound never pairs one
    # command's column with the other's issue.
    if [[ "$target" == "In review" ]] && rest="$(rest_pr_from_command "$command")"; then
        # The created PR echoed on stdout is what was sent; the --input file is re-read only after the
        # whole command ended, and a later command may have rewritten it (#902 review).
        local sent
        if sent="$(response_pr_head "$payload")"; then rest="$sent"; fi
        read -r owner repo rest_head <<<"$rest"
        issue="$(branch_issue "$rest_head")" || exit 0
    elif [[ "$target" == "In review" ]] && ! printf '%s' "$command" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+create'; then
        # A REST PR whose head can no longer be read must not fall back to HEAD.
        # ponytail: `--input f && rm f` lands here (no verb, no card move); fail-safe, not a wrong card.
        exit 0
    else
        read -r owner repo < <(owner_repo) || exit 0
        [[ -n "$owner" && -n "$repo" ]] || exit 0
        # issue.md names branches `<type>/<N>-<slug>`, so the branch carries the ref. `checkout -b`
        # checks the branch out, but `gh pr create --head <b>` may target a branch that is NOT HEAD
        # (dev-loop RESCUE opens PRs for other worktrees' branches from the main checkout) — then
        # the card to move is <b>'s, and HEAD is the wrong answer (#591).
        issue="$(issue_for_command "$command")" || exit 0
    fi
    [[ -n "$issue" ]] || exit 0

    # A failed PR-open (non-zero exit, HTTP error, no PR URL) must not move the card (#865).
    if [[ "$target" == "In review" ]]; then
        local is_cli=0
        printf '%s' "$command" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+create' && is_cli=1
        ! tool_response_failed "$payload" "$is_cli" || exit 0
    fi

    [[ "$(issue_state "$owner" "$repo" "$issue")" != "CLOSED" ]] || exit 0

    resolve_board "$owner" "$repo" "$issue" "$target" || exit 0
    [[ "$project_number" == "AMBIGUOUS" ]] && { warn_ambiguous "$repo"; exit 0; }
    [[ -n "$project_number" && -n "$option_id" ]] || exit 0

    item_id="$(card_item_id "$project_number" "$owner" "$issue")" \
        || { warn_failed "$repo" "$issue" "$target" "read the board's cards"; exit 0; }
    [[ -n "$item_id" ]] || exit 0     # issue not on the board → nothing to move

    if ! move_card "$project_node" "$item_id" "$status_field" "$option_id"; then
        # A stale cache is the likely cause — refresh once and retry before giving up.
        rm -f "$(cache_file "$owner" "$repo")"
        resolve_board "$owner" "$repo" "$issue" "$target" || exit 0
        move_card "$project_node" "$item_id" "$status_field" "$option_id" \
            || { warn_failed "$repo" "$issue" "$target" "move the card"; exit 0; }
    fi

    announce "$issue" "$target"
}

select_lifecycle_segment() {
    # Set target, segment and cd_path from the LAST segment of command $1 holding a lifecycle verb,
    # or return 1. This runs only after the whole command succeeded, so the last verb is the card's
    # final state: `checkout -b x && git push && gh pr create` ends In review, not In progress. The substring gate keeps python off the path of every other Bash call.
    printf '%s' "$1" | grep -Eq 'checkout|switch|pr[[:space:]]+create|api[[:space:]].*pulls' || return 1
    local record path seg column found=1
    while IFS= read -r -d '' record; do
        path="${record%%$'\x1f'*}"
        seg="${record#*$'\x1f'}"
        # In a subshell at that path, so a relative `--input <file>` resolves where the command ran.
        column="$(if [[ -n "$path" ]]; then cd "$path" 2>/dev/null || exit 1; fi; target_column "$seg")" \
            || continue
        target="$column" segment="$seg" cd_path="$path" found=0
    done < <(command_segments "$1")
    return "$found"
}

command_segments() {
    # NUL-terminated `<cd path>\x1f<segment>` records for command $1, the path empty until a literal
    # `cd`. A command that cannot be tokenized comes back whole, as one segment with no path.
    KANBAN_CMD="$1" python3 - "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null <<'PY' && return 0
import os, re, shlex, sys
sys.path.insert(0, sys.argv[1])
import gh_cmd_match as g

SAFE = {"git", "gh", "rtk", "echo", "printf", "cat", "mkdir", "rm", "touch", "ls", "true", "false",
        "test", "[", "jq", "sleep", "make", "mktemp", "cp", "mv", "grep", "python3", "curl", "bats"}
REDIR = re.compile(r"\d*(?:>>?|<<?<?|>&|<&|&>>?)(.*)")


def drop_redirects(argv):
    """argv without its redirects: `2>&1`, `>f`, and an operator with its target in the next word."""
    out, skip = [], False
    for word in argv:
        if skip:
            skip = False
            continue
        m = REDIR.fullmatch(word)
        if m:
            skip = not m.group(1)
            continue
        out.append(word)
    return out


try:
    command = os.environ["KANBAN_CMD"]
    path, out, pos = "", [], 0
    for segment in g.split_segments(command):
        start = command.find(segment, pos)
        gap = command[pos:start] if start >= 0 else "|"  # unlocatable segment: refuse to carry
        pos = start + len(segment) if start >= 0 else pos
        # Once a `cd` was seen, the path only carries across `&&`, `;` or a newline: after `||` the
        # verb runs when the cd failed, and `|` or a lone `&` put the next segment in another shell.
        if path and gap and re.search(r"\||(?<!&)&(?!&)", gap):
            break
        argv = drop_redirects(shlex.split(segment))
        if argv[:1] == ["cd"]:
            if len(argv) != 2 or argv[1].startswith(("-", "~")) or re.search(r"[$`{}]", argv[1]):
                break
            path = os.path.join(path, argv[1])
            continue
        # Allowlist, not denylist: only a known external command cannot change this shell's directory.
        # `eval`, `source`, `exec`, functions, `pushd`, `if`, `(`... all stop the scan, not guess.
        assign = re.compile(r"[A-Za-z_]\w*=")
        words = [w for w in argv if not assign.match(w)] if argv[:1] and assign.match(argv[0]) else argv
        if not words or words[0] not in SAFE:
            break
        out.append(f"{path}\x1f{segment}\0")
    sys.stdout.write("".join(out))  # only once every segment parsed, so the fallback never mixes
except ValueError:
    sys.exit(1)
PY
    printf '\x1f%s\0' "$1"
}

target_column() {
    # Map the Bash verb to its target column, or return 1 when it is neither lifecycle verb.
    local cmd="$1"
    if printf '%s' "$cmd" \
        | grep -Ezq '^[[:space:]]*(rtk[[:space:]]+)?git[[:space:]]+(checkout[[:space:]]+(.*[[:space:]])?-[bB]|switch[[:space:]]+(.*[[:space:]])?(-[cC]|--(force-)?create([[:space:]=]|$)))'; then
        printf 'In progress'; return 0
    fi
    if printf '%s' "$cmd" \
        | grep -Ezq '^[[:space:]]*(rtk[[:space:]]+)?gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
        printf 'In review'; return 0
    fi
    # Cheap gate first: python only spawns for a command that could be `gh api .../pulls`.
    if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_])api[[:space:]].*pulls' \
        && rest_pr_from_command "$cmd" >/dev/null; then
        printf 'In review'; return 0
    fi
    return 1
}

rest_pr_from_command() {
    # `<owner> <repo> <branch>` for a `[rtk] gh api repos/<o>/<r>/pulls` call that creates a PR
    # (#859): POST — explicit `-X`/`--method POST`, or implicit when a field flag is given and no
    # method is — carrying a `head=<branch>` field via -f/-F/--field/--raw-field (any spelling,
    # `--field=head=x` and `-fhead=x` included), or with `head` in an `--input` JSON file (#900).
    # Returns 1 for everything else: a GET, an unreadable input file, a
    # `pulls/<n>/...` subpath, no head field, or an owner/repo/head the shell builds (`$VAR`).
    # Tokenizes with gh_cmd_match.py's own argv helpers, so a `pulls` inside a quoted argument or
    # an `echo` is not mistaken for the call.
    KANBAN_CMD="$1" python3 - "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null <<'PY'
import json, os, re, sys
sys.path.insert(0, sys.argv[1])
import gh_cmd_match as g

PULLS = re.compile(r"^/?repos/([^/]+)/([^/]+)/pulls$")
DYNAMIC = re.compile(r"[$`{}]")


def head_from_input(str_path):
    # The `head` of the JSON body file, or "" for stdin, a path the shell builds, or a bad file.
    # `~`: shlex cannot tell `'~/f'` (literal, gh reads ./~/f) from `~/f` (shell-expanded).
    if str_path == "-" or DYNAMIC.search(str_path) or str_path.startswith("~"):
        return ""
    try:
        with open(str_path, encoding="utf-8") as cls_file:
            head = json.load(cls_file).get("head")
    except (OSError, ValueError, AttributeError):
        return ""
    return head if isinstance(head, str) else ""


def parse_api(rest):
    method, fields, input_path, endpoint = None, [], None, None
    i = 0
    while i < len(rest):
        tok = rest[i]
        name, inline = (tok.partition("=")[0], tok.partition("=")[2]) if tok.startswith("--") else (tok, "")
        if tok[:1] == "-" and tok[1:2] != "-" and len(tok) > 2 and tok[:2] in g.API_VALUE_FLAGS:
            name, inline = tok[:2], tok[2:].lstrip("=")
        if name in g.API_VALUE_FLAGS:
            attached = bool(inline) or tok != name
            value = inline if attached else (rest[i + 1] if i + 1 < len(rest) else "")
            kind = g.API_VALUE_FLAGS[name]
            if kind == "method":
                method = value.upper()
            elif kind == "field":
                fields.append(value)
            else:
                input_path = value
            i += 1 if attached else 2
        elif name in g.API_OTHER_VALUE_FLAGS:
            i += 1 if inline or (len(tok) > 2 and tok[1] != "-") else 2
        elif tok.startswith("-"):
            i += 1
        else:
            endpoint = endpoint or tok
            i += 1
    # With --input, gh sends -f/-F as query parameters; the body (and its head) is the file's.
    has_input = input_path is not None
    fields = [f"head={head_from_input(input_path)}"] if has_input else fields
    return endpoint, method or ("POST" if fields else "GET"), fields


try:
    for argv in g.iter_argvs(g.split_segments(os.environ["KANBAN_CMD"])):
        at = g.gh_start(argv)
        sub = g.gh_sub(argv, at) if at >= 0 else -1
        if sub < 0 or argv[sub:sub + 1] != ["api"]:
            continue
        endpoint, method, fields = parse_api(argv[sub + 1:])
        path = re.sub(r"^https?://[^/]+/(api/v3/)?", "", (endpoint or "").split("?", 1)[0]).rstrip("/")
        m = PULLS.match(path)
        heads = [f.partition("=")[2] for f in fields if f.partition("=")[0] == "head"]
        head = heads[-1].split(":")[-1] if heads else ""
        # `-F head=@file` makes gh read the value from a file, so the text is not the branch.
        if method == "POST" and m and head and not head.startswith("@") and not DYNAMIC.search(path + head):
            print(m.group(1), m.group(2), head)
            sys.exit(0)
except ValueError:
    pass
sys.exit(1)
PY
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
    branch_issue "$branch"
}

branch_issue() {
    # Leftmost number run in branch name $1 (feat/46-slug → 46), or return 1 when it has none.
    [[ "$1" =~ (^|[^0-9])([0-9]+)([^0-9]|$) ]] || return 1
    printf '%s' "$((10#${BASH_REMATCH[2]}))"   # 007 → 7: jq --argjson rejects leading zeros
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
    local cards
    # Read first, so a gh failure (return 1) is told apart from "issue not on the board" (empty).
    cards="$(gh project item-list "$num" --owner "$owner" --format json --limit 500 2>/dev/null)" \
        || return 1
    printf '%s' "$cards" \
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

warn_failed() {
    # $1 repo, $2 issue, $3 target column, $4 the step that failed. Never blocks — PostToolUse.
    jq -n --arg repo "$1" --argjson n "$2" --arg col "$3" --arg step "$4" '{
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: ("kanban_lifecycle: could NOT \($step) on the \"\($repo) kanban\" board — issue #\($n)'"'"'s card was NOT moved to \"\($col)\" (gh failed; often a GraphQL rate limit). Move it by hand once the limit resets: `gh project item-edit`, or re-run the reconcile.")
        }
    }' 2>/dev/null || true
}

resolve_board() {
    # Sets project_number/project_node/status_field/option_id (main's globals) from board_config.
    # Returns 1 on no board (silent) or a gh failure (warns); board_config's own status tells the
    # two apart (#865): 3 = no board, anything else non-zero = gh error.
    local out rc=0
    out="$(board_config "$1" "$2" "$4")" || rc=$?
    if (( rc != 0 )); then
        (( rc == 3 )) || warn_failed "$2" "$3" "$4" "read the board"
        return 1
    fi
    read -r project_number project_node status_field option_id <<<"$out"
}

response_pr_head() {
    # `<owner> <repo> <head>` of the LAST pull-request JSON object in the payload's ($1) stdout,
    # or return 1 when none is there (`--jq`, `--silent`, redirected output).
    printf '%s' "$1" | jq -r '.tool_response.stdout // empty | strings' 2>/dev/null | python3 -c '
import json, sys
text, dec, found, i = sys.stdin.read(), json.JSONDecoder(), None, 0
while (i := text.find("{", i)) != -1:
    try:
        obj, end = dec.raw_decode(text, i)
    except ValueError:
        i += 1
        continue
    head, base = obj.get("head"), obj.get("base")
    if isinstance(head, dict) and isinstance(base, dict) and isinstance(head.get("ref"), str):
        full, ref = (base.get("repo") or {}).get("full_name", ""), head["ref"]
        if isinstance(full, str) and full.count("/") == 1 and ref and not any(c.isspace() for c in full + ref):
            found = full.replace("/", " ") + " " + ref
    i = end
sys.exit(1) if found is None else print(found)
'
}

tool_response_failed() {
    # True when the PostToolUse payload ($1) shows the command FAILED (#865). Missing/unknown
    # shape fails open (not failed). Signals: non-zero exit code, is_error, a string response
    # starting "Error", an HTTP 4xx/5xx in stderr (gh api), or — for `gh pr create` ($2=1) —
    # NON-EMPTY stdout with no pull URL in stdout or stderr. Empty stdout (redirected, `--web`)
    # fails open: the URL is simply not observable.
    printf '%s' "$1" | jq -e --argjson pr "$2" '
        .tool_response as $r
        | if $r == null then false
          elif ($r | type) == "string" then ($r | test("^Error"))
          elif ($r | type) != "object" then false
          else
            ((($r.exit_code // $r.exitCode // $r.returncode // 0) | tostring) != "0")
            or ($r.is_error == true) or ($r.isError == true)
            or (($r.stderr // "") | test("\\(HTTP [45][0-9][0-9]\\)"))
            or ($pr == 1 and ($r.stdout | type) == "string" and ($r.stdout | test("\\S"))
                and ((($r.stdout + " " + ($r.stderr // "")) | test("/pull/[0-9]+|PR #[0-9]+")) | not))
          end' >/dev/null 2>&1
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
