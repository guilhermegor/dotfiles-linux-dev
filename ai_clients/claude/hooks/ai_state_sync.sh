#!/bin/bash
# AI-state sync (dotfiles-linux-dev#655): keep authored ~/.claude state (memories,
# corrections log, specs/plans, issue-trackers.conf) in a PRIVATE git repo so two
# machines never fork it. One script, three subcommands, two callers:
#
#   pull   `git pull --rebase --autostash`; a conflict is reported, never resolved.
#   push   secret-guard, commit whitelisted changes, push; "nothing to push" is a
#          clean no-op.
#   setup  Step `state_sync` (lib/state_sync.sh): clone + materialise on a fresh
#          machine; REFUSES to overwrite a divergent live file.
#
# Callers: the SessionStart/SessionEnd hooks pass `--hook` (always exit 0, near
# silent, fail-open). The standalone `~/.local/bin/ai-state-sync` (this same
# file, installed by the step) is for a keyboard shortcut or a terminal: it
# prints the outcome, uses notify-send when there is no TTY, and exits non-zero on
# failure.
#
# Design: a git WORK-TREE over the live dir (git dir kept outside it, work tree =
# ~/.claude), not symlinks. Membership is a whitelist in the git dir's
# info/exclude. A work-tree needs no per-path link, so a project memory dir
# created tomorrow is picked up with no re-run, and nothing in ~/.claude is ever
# replaced by a link.
#
# Conflicts are NEVER auto-resolved: they are reported forward through a handoff
# file ($CLAUDE_DIR/session-audit/ai-state-sync.md) that the next `pull` prints,
# the same report-forward contract as session_capture_audit.sh --handoff.
#
# Extension point for codex/qwen/copilot state (#656): everything below is keyed
# on AI_STATE_GIT_DIR + AI_STATE_WORK_TREE + WHITELIST; a second client is a
# second invocation with those three set, no change to the modes.
#
# Env: AI_STATE_REPO (default guilhermegor/ai-clients-state), AI_STATE_REMOTE
# (full URL override, used by tests), AI_STATE_GIT_DIR, AI_STATE_WORK_TREE,
# AI_STATE_TIMEOUT (seconds per network call, default 20).
set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AI_STATE_REPO="${AI_STATE_REPO:-guilhermegor/ai-clients-state}"
AI_STATE_REMOTE="${AI_STATE_REMOTE:-git@github.com:${AI_STATE_REPO}.git}"
AI_STATE_GIT_DIR="${AI_STATE_GIT_DIR:-$HOME/.ai-clients-state/claude.git}"
AI_STATE_WORK_TREE="${AI_STATE_WORK_TREE:-$CLAUDE_DIR}"
AI_STATE_TIMEOUT="${AI_STATE_TIMEOUT:-20}"
BRANCH="main"
HOOK=0 # 1 under --hook: always exit 0, speak only on a pull conflict
MODE=""
SECRET_HELD=""
REFUSAL=""
HANDOFF="$CLAUDE_DIR/session-audit/ai-state-sync.md"

# Whitelist, never a blacklist: ignore everything at the top level, re-include
# named paths. Last match wins, so the trailing deny lines are a belt over the
# braces for the "never credentials / transcripts" rule.
WHITELIST='/*
!/memory/
!/tasks/
!/specs/
!/plans/
!/issue-trackers.conf
!/projects/
/projects/*
!/projects/*/
/projects/*/*
!/projects/*/memory/
*.jsonl
.env
.env.*
.credentials.json'

# Same patterns as commit_secret_guard.sh (kept in sync by hand: that hook reads a
# PreToolUse payload, so it cannot be reused here). Only unambiguous token shapes
# and PEM keys: a password-style assignment heuristic would false-positive on
# memory prose and wedge the sync forever. The PEM marker is built from
# fragments so this file does not trip the scanner itself.
TOKEN_RE='(AKIA[0-9A-Z]{16}|gh[oprsu]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{22,}|xox[baprs]-[0-9A-Za-z-]{10,}|AIza[0-9A-Za-z_-]{35}|(sk|rk)_live_[0-9A-Za-z]{20,})'
PK_BEGIN="-----BEGIN "
PK_END="PRIVATE KEY-----"

g() { git --git-dir="$AI_STATE_GIT_DIR" --work-tree="$AI_STATE_WORK_TREE" "$@"; }
net() { GIT_TERMINAL_PROMPT=0 timeout "$AI_STATE_TIMEOUT" "$@"; }
say() { printf '%s\n' "[ai-state-sync] $*"; }

write_excludes() {
    mkdir -p "$AI_STATE_GIT_DIR/info"
    printf '%s\n' "$WHITELIST" >"$AI_STATE_GIT_DIR/info/exclude"
}

configure_repo() {
    g config core.bare false
    g config core.excludesFile /dev/null
    g config user.name >/dev/null 2>&1 || g config user.name "ai-state-sync"
    g config user.email >/dev/null 2>&1 || g config user.email "ai-state-sync@localhost"
    write_excludes
}

unmerged_files() { g diff --name-only --diff-filter=U 2>/dev/null; }

# Scan exactly what `git commit` will record: the STAGED BLOB of every added /
# modified / copied / renamed path, whole file, bytes as stored. Not the diff text:
# a diff scan is blind to binary-classified files (no "+" lines), and a path it
# parses out of `+++ b/<name>` is quoted/tab-suffixed for names with spaces or
# non-ASCII, which then fails to match the real path when it is unstaged -- a
# planted token was committed anyway (security review, #655). Paths are NUL-
# delimited end to end. Prints NUL-delimited file names only, never the matched
# text (the report must not echo the secret it found).
#
# Never decide on a pipeline status: `cat-file | grep -q` under pipefail reads a
# MATCH as 141 (grep exits early, the writer takes SIGPIPE) once the file passes the
# pipe buffer, i.e. fail-open. The blob goes to a temp file first and ONLY grep's
# own status counts: 1 = clean, anything else (match, read error, grep error) =
# flagged, so an unknown outcome blocks the commit.
#
# Contract (fail closed): every guard_* function returns 0 ONLY on a positive,
# completed "clean" verdict. 1 = flagged (FLAGGED holds the paths), 2 = the scan could
# not complete (listing failed, no temp file, ...). Callers treat anything but 0 as
# "do not commit / do not push". No status is ever swallowed, and no list is built
# through a process substitution whose own failure would read as "empty = clean".
FLAGGED=()

# scan_blobs <NUL-delimited path listing file> <blob prefix>
scan_blobs() {
    local listing="$1" prefix="$2" path scan rc
    FLAGGED=()
    scan="$(mktemp)" || return 2
    while IFS= read -r -d '' path; do
        if ! g cat-file blob "$prefix$path" >"$scan" 2>/dev/null; then
            FLAGGED+=("$path") # unreadable blob: unknown, so refuse
            continue
        fi
        grep -aEq -e "$TOKEN_RE" -e "${PK_BEGIN}[A-Z ]*${PK_END}" "$scan"
        rc=$?
        [ "$rc" -eq 1 ] || FLAGGED+=("$path") # 0 = match; >=2 = grep error
    done <"$listing"
    rm -f "$scan"
    [ "${#FLAGGED[@]}" -eq 0 ]
}

# guard_staged: what the next `git commit` would record.
guard_staged() {
    local listing rc
    listing="$(mktemp)" || return 2
    if ! g diff --cached --name-only -z --no-renames --diff-filter=ACMRT >"$listing" 2>/dev/null; then
        rm -f "$listing"
        return 2
    fi
    scan_blobs "$listing" ":0:"
    rc=$?
    rm -f "$listing"
    return "$rc"
}

# guard_unpushed: what a push would publish, including commits this run did not make
# (a manual commit, a leftover from an earlier run) that never passed guard_staged.
# Only the net tree difference vs origin is scanned, not intermediate commits.
guard_unpushed() {
    local listing rc failed=0
    listing="$(mktemp)" || return 2
    if g rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
        g diff --name-only -z --no-renames --diff-filter=ACMRT "origin/$BRANCH" HEAD >"$listing" 2>/dev/null || failed=1
    else
        g ls-tree -r -z --name-only HEAD >"$listing" 2>/dev/null || failed=1
    fi
    if [ "$failed" -ne 0 ]; then
        rm -f "$listing"
        return 2
    fi
    scan_blobs "$listing" "HEAD:"
    rc=$?
    rm -f "$listing"
    return "$rc"
}

report_forward() {
    mkdir -p "$(dirname "$HANDOFF")" 2>/dev/null || return 0
    printf '%s\n' "$*" >"$HANDOFF" 2>/dev/null || true
}

# End the run. CLI use (shortcut / terminal): print the outcome, mirror it to
# notify-send when there is no TTY (a GNOME shortcut has none), exit with rc.
# Hook use (--hook): always exit 0 so a session never stalls or fails to close;
# a pull CONFLICT is the one thing printed, because SessionStart stdout reaches
# Claude. Offline and "not set up" stay silent (fail open).
finish() {
    local rc="$1" msg="$2"
    if [ "$HOOK" = 1 ]; then
        [ "$rc" -eq 2 ] && say "$msg"
        exit 0
    fi
    say "$msg"
    if [ ! -t 1 ] && command -v notify-send >/dev/null 2>&1; then
        notify-send "AI state sync ($MODE)" "$msg" >/dev/null 2>&1 || true
    fi
    [ "$rc" -eq 0 ] && exit 0
    exit 1
}

not_set_up() {
    finish 1 "not set up: run ./ai_clients/claude/main.sh state_sync (missing $AI_STATE_GIT_DIR)"
}

# rc 2 = a problem worth surfacing even from a hook.
mode_pull() {
    [ -d "$AI_STATE_GIT_DIR" ] || not_set_up
    write_excludes
    if [ "$HOOK" = 1 ] && [ -f "$HANDOFF" ]; then
        say "Unresolved state-sync problem from your last session:"
        cat "$HANDOFF"
    fi
    if net git --git-dir="$AI_STATE_GIT_DIR" --work-tree="$AI_STATE_WORK_TREE" \
        pull --rebase --autostash -q origin "$BRANCH" >/dev/null 2>&1; then
        rm -f "$HANDOFF" 2>/dev/null || true
        finish 0 "pulled: AI state is up to date"
    fi
    local conflicts msg
    conflicts="$(unmerged_files)"
    if [ -n "$conflicts" ]; then
        msg="CONFLICT pulling AI state. NOT auto-resolved. Fix these files in $AI_STATE_WORK_TREE, then run: git --git-dir=$AI_STATE_GIT_DIR --work-tree=$AI_STATE_WORK_TREE add -A
$conflicts"
        report_forward "$msg"
        finish 2 "$msg"
    fi
    finish 1 "pull failed (offline, timeout, or the remote has no $BRANCH yet); nothing changed"
}

# Commit whitelisted changes minus any file the secret guard flags.
commit_changes() {
    g add -A >/dev/null 2>&1 || { REFUSAL="git add failed"; return 1; }
    local f rc blocked
    guard_staged
    rc=$?
    if [ "$rc" -eq 1 ]; then
        blocked=("${FLAGGED[@]}")
        for f in "${blocked[@]}"; do
            GIT_LITERAL_PATHSPECS=1 g reset -q -- "$f" >/dev/null 2>&1
        done
        SECRET_HELD="$(printf '%s ' "${blocked[@]}")"
        report_forward "SECRET GUARD held back these files (not committed, not pushed); remove the secret, they sync on the next run:
$(printf '%s\n' "${blocked[@]}")"
        guard_staged # re-verify: anything still flagged means the unstage failed
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        g reset -q >/dev/null 2>&1 # unknown or still flagged: commit nothing at all
        REFUSAL="secret scan did not return a clean verdict (status $rc); nothing committed"
        report_forward "$REFUSAL"
        return 1
    fi
    g diff --cached --quiet
    case $? in
        0) return 0 ;;                        # nothing staged
        1) ;;                                 # changes: fall through to commit
        *) REFUSAL="could not tell what is staged"; return 1 ;;
    esac
    g commit -q -m "chore(state): sync $(hostname -s 2>/dev/null || echo host) $(date -u +%FT%TZ)" >/dev/null 2>&1 ||
        { REFUSAL="git commit failed"; return 1; }
}

commits_ahead() {
    g rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null ||
        g rev-list --count HEAD 2>/dev/null || echo 0
}

push_head() {
    net git --git-dir="$AI_STATE_GIT_DIR" --work-tree="$AI_STATE_WORK_TREE" \
        push -q origin "HEAD:$BRANCH" >/dev/null 2>&1
}

mode_push() {
    [ -d "$AI_STATE_GIT_DIR" ] || not_set_up
    configure_repo
    local unmerged held="" rc=0 msg
    unmerged="$(unmerged_files)"
    if [ -n "$unmerged" ]; then
        report_forward "Unmerged AI-state files block syncing; resolve them in $AI_STATE_WORK_TREE:
$unmerged"
        finish 1 "unmerged files block syncing: $unmerged"
    fi
    rm -f "$HANDOFF" 2>/dev/null || true # re-evaluated from scratch every run
    commit_changes || finish 1 "commit refused: $REFUSAL"
    [ -n "$SECRET_HELD" ] && { held=" Secret guard held back: $SECRET_HELD"; rc=1; }

    if [ "$(commits_ahead)" -eq 0 ]; then
        finish "$rc" "nothing to push.$held"
    fi
    guard_unpushed || finish 1 "push refused: the secret scan of what would be published did not come back clean (see $HANDOFF)"
    if ! push_head; then
        # Remote moved ahead: rebase once; a conflict is reported, never resolved.
        if net git --git-dir="$AI_STATE_GIT_DIR" --work-tree="$AI_STATE_WORK_TREE" \
            pull --rebase -q origin "$BRANCH" >/dev/null 2>&1; then
            push_head || finish 1 "push failed after rebase (offline?).$held"
        elif [ -n "$(unmerged_files)" ]; then
            g rebase --abort >/dev/null 2>&1
            msg="CONFLICT pushing AI state: the remote changed the same files. Nothing was overwritten; local commits are kept. Resolve with: git --git-dir=$AI_STATE_GIT_DIR --work-tree=$AI_STATE_WORK_TREE pull --rebase"
            report_forward "$msg"
            finish 1 "$msg"
        else
            finish 1 "push failed (offline or timeout); commits kept locally.$held"
        fi
    fi
    finish "$rc" "pushed.$held"
}

# Echo live files that exist AND differ from origin/$BRANCH's copy.
divergent_files() {
    local path
    while IFS= read -r path; do
        [ -e "$AI_STATE_WORK_TREE/$path" ] || continue
        g cat-file blob "origin/$BRANCH:$path" 2>/dev/null |
            cmp -s - "$AI_STATE_WORK_TREE/$path" || printf '%s\n' "$path"
    done < <(g ls-tree -r --name-only "origin/$BRANCH" 2>/dev/null)
}

mode_setup() {
    if [ -d "$AI_STATE_GIT_DIR" ]; then
        say "already set up: $AI_STATE_GIT_DIR"
        return 0
    fi
    if ! net git ls-remote "$AI_STATE_REMOTE" >/dev/null 2>&1; then
        say "remote $AI_STATE_REMOTE not reachable or does not exist; nothing done."
        say "Create it once (private), then re-run this step:"
        say "  gh repo create $AI_STATE_REPO --private"
        return 0
    fi

    mkdir -p "$AI_STATE_GIT_DIR" "$AI_STATE_WORK_TREE" || return 1
    g init -q -b "$BRANCH" >/dev/null 2>&1 || g init -q >/dev/null 2>&1
    g symbolic-ref HEAD "refs/heads/$BRANCH"
    configure_repo
    g remote add origin "$AI_STATE_REMOTE"

    if net git --git-dir="$AI_STATE_GIT_DIR" --work-tree="$AI_STATE_WORK_TREE" \
        fetch -q origin "$BRANCH" >/dev/null 2>&1; then
        local diverged
        diverged="$(divergent_files)"
        if [ -n "$diverged" ]; then
            rm -rf "$AI_STATE_GIT_DIR"
            say "REFUSING to overwrite live files that differ from the state repo:"
            printf '%s\n' "$diverged" | sed 's/^/  /'
            say "Move or merge them by hand, then re-run this step."
            return 1
        fi
        g checkout -q -f -B "$BRANCH" "origin/$BRANCH" >/dev/null 2>&1 || return 1
        g branch -q --set-upstream-to="origin/$BRANCH" "$BRANCH" >/dev/null 2>&1
        say "state restored from $AI_STATE_REMOTE into $AI_STATE_WORK_TREE"
    else
        say "remote is empty: the first SessionEnd (or a manual push) seeds it."
    fi
}

main() {
    MODE="${1:-}"
    [ "${2:-}" = "--hook" ] && HOOK=1
    [ "$HOOK" = 1 ] && cat >/dev/null 2>&1 # drain the hook's JSON payload
    case "$MODE" in
        pull) mode_pull ;;
        push) mode_push ;;
        setup) mode_setup ;;
        *) say "usage: ai_state_sync.sh pull|push|setup"; exit 0 ;;
    esac
}

main "$@"
