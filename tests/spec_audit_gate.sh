#!/bin/bash
#
# tests/spec_audit_gate.sh
#
# CI gate (dotfiles-linux-dev#305): a MECHANICAL verdict on whether a feature spec under
# .specs/features/<name>/ is aligned with its tests. exit 0 = aligned. exit 1 = the
# exact list of what is missing, one finding per line, each citing file:line.
#
# Why a gate and not a hook: a PreToolUse hook fires on a tool call and has no
# notion of "the feature is finished" -- it would fire on every edit or never.
# This script is pure text processing with a deterministic verdict, the same
# shape as tests/validate_contracts.sh (a CI-only gate, not a PreToolUse hook --
# the closer analogue) and the parse logic in
# ai_clients/claude/hooks/pr_merge_threads_guard.sh /
# ai_clients/claude/hooks/release_dispatch_guard.sh.
#
# ⚠️ FORMAT NOTE (read before touching the regexes below): this gate checks
# `spec.md`, which .specs/CLAUDE.md names as the ALWAYS-PRESENT per-feature file
# (`s:work-breakdown`'s output). The other three are conditional: `design.md` and
# `tasks.md` appear only at Large scope, `plan.md` only when `s:writing-plans`
# ran. Checking a conditional file would report SECTION_MISSING for every small
# feature that correctly omitted it -- so the always-present one is the only
# sound anchor for anything s:work-breakdown produced.
#
# EXCEPTION: a feature with design.md (s:brainstorming) and/or plan.md
# (s:writing-plans) but no spec.md is the older, still-valid two-skill
# workflow that pre-dates s:work-breakdown -- it never produces a spec.md at
# all, by design. `check_feature()` treats that shape as aligned rather than
# SECTION_MISSING (dotfiles-linux-dev#375: every feature migrated from
# docs/superpowers/ is exactly this shape).
#
# The id syntax below is this gate's OWN minimal convention: .specs/CLAUDE.md
# defines the file layout but no marker grammar. It is scoped to exactly the five
# findings #305 asks for, no more. If a spec-writing change lands something
# incompatible, this grammar is what changes, not the five finding names.
#
# Grammar parsed out of <feature-dir>/spec.md:
#   Acceptance criteria : any occurrence of the literal pattern `AC-<n>`.
#   Assumptions section : a markdown heading line whose text contains the word
#                         "assumptions" (case-insensitive), e.g. `## Assumptions`.
#                         An absent heading is SECTION_MISSING; a heading present
#                         with body text "None" (or anything else) PASSES -- an
#                         absent section and an empty one are different claims.
#   Assumption entries  : any occurrence of `ASM-<n>`. OPEN unless that entry's
#                         line also contains the literal tag `(resolved)`.
#   Question entries    : any occurrence of `Q-<n>`. OPEN unless that entry's
#                         line also contains the literal tag `(answered)`.
# A test references an acceptance criterion by putting the literal tag
# `@AC-<n>` anywhere in a file under --tests-dir (default: tests/).
#
# Grammar parsed out of <feature-dir>/progress.md (dotfiles-linux-dev#313) -- a THREE-state
# checkbox list, one entry per markdown list item:
#   `- [ ] ...`  to do
#   `- [~] ...`  IN PROGRESS  <- the whole point: the state git cannot represent
#   `- [x] ...`  done
# progress.md is OPTIONAL. A feature without one is NOT a finding and the gate stays
# silent about it -- same reason the gate anchors on spec.md, the always-present file:
# a check on a conditional file reports on every feature that correctly omitted it.
# TRACKER_STALE fires only when all three hold: the file exists, it carries at least
# one `[~]`, and its mtime predates the newest commit touching the feature directory
# (i.e. the work moved and the declared in-flight state did not). It is a FINDING like
# the other five, never a hard block -- a stale tracker misleads, it does not break the
# build. It fails open (silent) when git cannot answer: no repo, no commits, no git.
#
# ponytail: the id patterns are plain substrings, not word-bounded -- a spec
# containing "REQ-3" would false-positive-match the `Q-[0-9]+` pattern. Add a
# boundary check if that ever fires for real; not worth it against today's
# fixtures.
#
# Usage:
#   tests/spec_audit_gate.sh [--tests-dir DIR] [feature-dir ...]
#   (no feature-dir given -> every directory under .specs/features/)
#
# Run locally: bash tests/spec_audit_gate.sh
# Wired into CI via .github/workflows/tests.yml (spec_audit job).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

TESTS_DIR="$REPO_ROOT/tests"
FINDINGS=()

usage() {
    echo "Usage: $(basename "$0") [--tests-dir DIR] [feature-dir ...]" >&2
}

# --- id scanning ------------------------------------------------------------

# Emit "<id> <line>" for the first occurrence of each id matching ID_REGEX in
# FILE. If RESOLVED_REGEX is non-empty, an id is emitted only when its first
# occurrence's line does NOT also match RESOLVED_REGEX (the "still open" case).
scan_ids() {
    local id_regex="$1" resolved_regex="$2" file="$3"
    local -A seen=()
    local lineno full_line scan id

    while IFS=: read -r lineno full_line; do
        scan="$full_line"
        while [[ "$scan" =~ $id_regex ]]; do
            id="${BASH_REMATCH[0]}"
            scan="${scan#*"$id"}"
            if [[ -n "${seen[$id]:-}" ]]; then
                continue
            fi
            seen[$id]=1
            if [[ -n "$resolved_regex" && "$full_line" =~ $resolved_regex ]]; then
                continue
            fi
            printf '%s %s\n' "$id" "$lineno"
        done
    done < <(grep -nE "$id_regex" "$file" 2>/dev/null)
}

# --- individual checks ------------------------------------------------------

check_section_missing() {
    local spec="$1"
    if ! grep -qiE '^#{1,6}[[:space:]]+.*assumptions' "$spec"; then
        FINDINGS+=("$spec:1: SECTION_MISSING no assumptions heading found\
 -- write 'None' under one if there genuinely are none")
    fi
}

check_acceptance_criteria() {
    local spec="$1" tests_dir="$2"
    local -A ac_lines=() tag_seen=()
    local id lineno file ac_id

    while read -r id lineno; do
        [[ -n "$id" ]] || continue
        ac_lines[$id]="$lineno"
    done < <(scan_ids 'AC-[0-9]+' '' "$spec")

    if [[ -d "$tests_dir" ]]; then
        while IFS= read -r -d '' file; do
            while read -r id lineno; do
                [[ -n "$id" ]] || continue
                ac_id="${id#@}"
                tag_seen[$ac_id]=1
                if [[ -z "${ac_lines[$ac_id]:-}" ]]; then
                    FINDINGS+=("$file:$lineno: TEST_WITHOUT_AC $id has no matching\
 acceptance criterion in $spec")
                fi
            done < <(scan_ids '@AC-[0-9]+' '' "$file")
        done < <(find "$tests_dir" -type f -print0 2>/dev/null)
    fi

    for id in "${!ac_lines[@]}"; do
        if [[ -z "${tag_seen[$id]:-}" ]]; then
            FINDINGS+=("$spec:${ac_lines[$id]}: AC_WITHOUT_TEST $id has no test tagged @$id")
        fi
    done
}

check_open_items() {
    local spec="$1" id_regex="$2" resolved_regex="$3" finding_name="$4" message="$5"
    local id lineno

    while read -r id lineno; do
        [[ -n "$id" ]] || continue
        FINDINGS+=("$spec:$lineno: $finding_name $id $message")
    done < <(scan_ids "$id_regex" "$resolved_regex" "$spec")
}

# Line number of the first `- [~]` entry in FILE, or nothing when there is none.
# The trailing `|| return 0` is load-bearing: "no match" is the common, legitimate
# answer here, and under `set -euo pipefail` grep's exit 1 would abort the gate.
first_in_progress_line() {
    local file="$1"
    grep -nE '^[[:space:]]*[-*+][[:space:]]+\[~\]' "$file" 2>/dev/null |
        head -n 1 | cut -d: -f1 || return 0
}

# Commit timestamp (epoch seconds) of the newest commit touching DIR. Non-zero exit
# when git cannot answer -- not a repo, no commits for that path, git absent.
newest_commit_epoch() {
    local dir="$1" epoch
    # `-- .` (not the absolute path) so the pathspec is resolved relative to -C,
    # which stays correct when the worktree root reaches the dir through a symlink.
    epoch="$(git -C "$dir" log -1 --format=%ct -- . 2>/dev/null)" || return 1
    [[ -n "$epoch" ]] || return 1
    printf '%s\n' "$epoch"
}

check_tracker_stale() {
    local feature_dir="$1"
    local tracker="$feature_dir/progress.md"
    [[ -f "$tracker" ]] || return 0

    local lineno
    lineno="$(first_in_progress_line "$tracker")"
    [[ -n "$lineno" ]] || return 0

    local commit_epoch tracker_epoch
    commit_epoch="$(newest_commit_epoch "$feature_dir")" || return 0
    tracker_epoch="$(stat -c %Y "$tracker" 2>/dev/null)" || return 0
    ((tracker_epoch < commit_epoch)) || return 0

    FINDINGS+=("$tracker:$lineno: TRACKER_STALE an in-progress [~] entry is older than\
 the newest commit touching '$feature_dir' -- update the tracker or clear the [~]")
}

check_feature() {
    local feature_dir="${1%/}" spec

    spec="$feature_dir/spec.md"

    # Before the spec.md guard: progress.md is independent of spec.md, so a feature
    # missing its spec still gets its tracker audited rather than only one finding.
    check_tracker_stale "$feature_dir"

    if [[ ! -f "$spec" ]]; then
        # ponytail: spec.md is s:work-breakdown's output, but .specs/CLAUDE.md also
        # documents an older, still-valid shape -- design.md (s:brainstorming) +
        # plan.md (s:writing-plans) with no spec.md ever produced. Discovered
        # 2026-09-14 (dotfiles-linux-dev#375) migrating docs/superpowers/ into real
        # .specs/features/ dirs: every one of those pre-dates work-breakdown and
        # is exactly this shape, so a blanket "spec.md missing" finding would fire
        # on legitimate features forever. Only flag when the dir has neither
        # plan.md nor design.md either -- an empty or bogus feature dir.
        if [[ ! -f "$feature_dir/plan.md" && ! -f "$feature_dir/design.md" ]]; then
            FINDINGS+=("$spec:1: SECTION_MISSING spec.md not found for feature dir '$feature_dir'")
        fi
        return
    fi

    check_section_missing "$spec"
    check_acceptance_criteria "$spec" "$TESTS_DIR"
    check_open_items "$spec" 'ASM-[0-9]+' '\(resolved\)' 'ASSUMPTION_OPEN' \
        'is still open -- resolve it or mark it (resolved)'
    check_open_items "$spec" 'Q-[0-9]+' '\(answered\)' 'QUESTION_OPEN' \
        'is still unanswered -- answer it or mark it (answered)'
}

# --- discovery + main --------------------------------------------------------

default_feature_dirs() {
    # Overridable so tests can point default discovery at a fixture tree instead
    # of the real repo's .specs/features/ (bats must never touch the real tree).
    local specs_dir="${SPEC_AUDIT_GATE_SPECS_DIR:-$REPO_ROOT/.specs/features}" d
    [[ -d "$specs_dir" ]] || return 0
    for d in "$specs_dir"/*/; do
        [[ -d "$d" ]] || continue
        printf '%s\n' "${d%/}"
    done
}

parse_args() {
    ARG_DIRS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tests-dir)
                TESTS_DIR="$2"
                shift 2
                ;;
            --tests-dir=*)
                TESTS_DIR="${1#*=}"
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                ARG_DIRS+=("$1")
                shift
                ;;
        esac
    done
}

main() {
    local -a ARG_DIRS=() feature_dirs=()
    parse_args "$@"

    if ((${#ARG_DIRS[@]} > 0)); then
        feature_dirs=("${ARG_DIRS[@]}")
    else
        mapfile -t feature_dirs < <(default_feature_dirs)
    fi

    if ((${#feature_dirs[@]} == 0)); then
        print_status "success" "No .specs/features/ directories to audit."
        exit 0
    fi

    local feature_dir
    for feature_dir in "${feature_dirs[@]}"; do
        check_feature "$feature_dir"
    done

    if ((${#FINDINGS[@]} == 0)); then
        print_status "success" "Spec audit gate: aligned -- ${#feature_dirs[@]} feature(s) checked."
        exit 0
    fi

    print_status "error" "Spec audit gate: ${#FINDINGS[@]} finding(s)."
    local f
    for f in "${FINDINGS[@]}"; do
        print_status "error" "$f"
    done
    exit 1
}

main "$@"
