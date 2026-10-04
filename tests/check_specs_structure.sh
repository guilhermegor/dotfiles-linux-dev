#!/bin/bash
#
# tests/check_specs_structure.sh
#
# CI + pre-commit gate (dotfiles-linux-dev#443): enforces the `.specs/` directory
# allowlist dotfiles-linux-dev#442 settled in `.specs/CLAUDE.md` -- the ONE place
# this convention is authored, and until now the one place it went
# unenforced. blueprintx has the same tree shape and its own
# bin/ci/check_specs_structure.sh (blueprintx#447); this is dotfiles-dev's
# own, separate implementation, not a shared one -- the two repos have no
# shared runtime to import from (blueprintx ships gates inside `templates/`,
# dotfiles-dev deploys via `make ai_clients`), so a second copy is adopted
# here deliberately, per #443's own instruction to record that choice.
#
# What it checks, purely by directory/file NAME -- content is
# tests/spec_audit_gate.sh's job, not this gate's:
#   - .specs/ top level: only CLAUDE.md, features/, backlog/, _lessons/ are
#     allowed. Anything else -- INCLUDING a type-folder like bugfix/ or
#     chore/ (dotfiles-linux-dev#442: deliberately rejected, recorded in
#     .specs/CLAUDE.md) -- fails as DISALLOWED_TOP_LEVEL. No special-casing
#     for type-folders: an allowlist already rejects anything not on it.
#   - .specs/CLAUDE.md must exist whenever .specs/ exists (#442).
#   - .specs/features/<name>/ must be a directory, its name kebab-case, and
#     its name must not lead with a bare issue number ("442-foo" fails,
#     "4k-downloader-media-folder" -- a real feature dir in this repo --
#     passes, because "4k" is not purely numeric). Must contain at least one
#     of spec.md / design.md / plan.md (tests/spec_audit_gate.sh's own
#     EXCEPTION for the pre-work-breakdown two-skill shape).
#   - .specs/backlog/<file> must be a kebab-case-slug.md (single naming
#     rule, chosen over blueprintx's `<topic>_YYYYMMDD_HHMMSS.md` for
#     consistency with features/ -- dotfiles-dev's own .specs/backlog/
#     starts empty, so there is no existing content to preserve the older
#     pattern for; see .specs/CLAUDE.md).
#   - .specs/_lessons/ is exempt entirely (dotfiles-linux-dev#386: a generated,
#     git-ignored mirror, not a work unit).
#
# ponytail: top-level discovery globs "$specs_dir"/* which skips dotfiles
# (.gitignore, .gitkeep) by design -- bash globs don't match a leading dot
# without `dotglob`. Not worth enabling for a tree with none today; revisit
# if a dotfile ever needs a rule.
#
# Usage:
#   tests/check_specs_structure.sh [SPECS_DIR]
#   (no SPECS_DIR given -> REPO_ROOT/.specs; missing dir -> pass silently,
#   same "nothing to check yet" behaviour as spec_audit_gate.sh)
#
# Run locally: bash tests/check_specs_structure.sh
# Wired into CI (.github/workflows/tests.yml, specs_structure job) AND the
# local pre-commit hook (.githooks/pre-commit) -- both legs, so
# `--no-verify` does not silently bypass it (dotfiles-linux-dev#443, the defect
# blueprintx#510 exists for).

set -euo pipefail

# dotglob: a deny-by-default allowlist that cannot SEE an entry admits it. The
# default glob skips dotfiles, so `.gitignore` under `.specs/` never reached
# check_top_level_entry and passed without ever being judged. nullglob is
# deliberately NOT set -- the `-e || -L` guards below rely on an unmatched glob
# expanding to a literal that is neither, which is how the empty-dir case
# short-circuits.
shopt -s dotglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

TOP_LEVEL_ALLOWLIST=("CLAUDE.md" "features" "backlog" "_lessons")
FINDINGS=()

usage() {
    echo "Usage: $(basename "$0") [SPECS_DIR]" >&2
}

is_allowed_top_level() {
    local name="$1" allowed
    for allowed in "${TOP_LEVEL_ALLOWLIST[@]}"; do
        [[ "$name" == "$allowed" ]] && return 0
    done
    return 1
}

is_kebab_case() {
    [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# "442-foo" -> true (the whole first segment before the first hyphen is
# digits-only, i.e. shaped like a bare issue number). "4k-downloader" ->
# false ("4k" is not digits-only).
leads_with_issue_number() {
    local first_segment="${1%%-*}"
    [[ "$first_segment" =~ ^[0-9]+$ ]]
}

check_feature_dir() {
    local dir="$1" name
    name="$(basename "$dir")"

    if [[ ! -d "$dir" ]]; then
        FINDINGS+=("$dir: NOT_A_DIRECTORY features/ may only contain feature directories")
        return
    fi

    if ! is_kebab_case "$name"; then
        FINDINGS+=("$dir: BAD_FEATURE_NAME '$name' is not kebab-case")
    elif leads_with_issue_number "$name"; then
        FINDINGS+=("$dir: BAD_FEATURE_NAME '$name' leads with a bare issue number -- an issue number is not a name")
    fi

    if [[ ! -f "$dir/spec.md" && ! -f "$dir/design.md" && ! -f "$dir/plan.md" ]]; then
        FINDINGS+=("$dir: MISSING_FEATURE_FILES needs at least one of spec.md, design.md, plan.md")
    fi
}

check_backlog_file() {
    local file="$1" name
    name="$(basename "$file")"

    if [[ -d "$file" ]]; then
        FINDINGS+=("$file: BACKLOG_SUBDIR backlog/ holds flat files, not subdirectories")
        return
    fi

    if [[ ! "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*\.md$ ]]; then
        FINDINGS+=("$file: BAD_BACKLOG_NAME '$name' must be a kebab-case-slug.md")
    fi
}

check_features_group() {
    local dir="$1" feature_dir
    if [[ ! -d "$dir" ]]; then
        FINDINGS+=("$dir: NOT_A_DIRECTORY features/ must be a directory")
        return
    fi
    for feature_dir in "$dir"/*; do
        [[ -e "$feature_dir" || -L "$feature_dir" ]] || continue
        check_feature_dir "$feature_dir"
    done
}

check_backlog_group() {
    local dir="$1" backlog_file
    if [[ ! -d "$dir" ]]; then
        FINDINGS+=("$dir: NOT_A_DIRECTORY backlog/ must be a directory")
        return
    fi
    for backlog_file in "$dir"/*; do
        [[ -e "$backlog_file" || -L "$backlog_file" ]] || continue
        check_backlog_file "$backlog_file"
    done
}

check_top_level_entry() {
    local entry="$1" name
    name="$(basename "$entry")"

    if ! is_allowed_top_level "$name"; then
        FINDINGS+=("$entry: DISALLOWED_TOP_LEVEL '$name' is not one of: ${TOP_LEVEL_ALLOWLIST[*]}")
        return
    fi

    case "$name" in
        CLAUDE.md)
            [[ -f "$entry" ]] || FINDINGS+=("$entry: NOT_A_FILE CLAUDE.md must be a regular file")
            ;;
        features)
            check_features_group "$entry"
            ;;
        backlog)
            check_backlog_group "$entry"
            ;;
        _lessons)
            : # exempt -- generated mirror, no naming rules (dotfiles-linux-dev#386)
            ;;
    esac
}

check_specs_dir() {
    local specs_dir="$1" entry

    for entry in "$specs_dir"/*; do
        # -L as well as -e: a DANGLING symlink fails -e, and skipping it would
        # walk a deny-by-default allowlist straight past an arbitrary name. An
        # unmatched glob is neither, so the empty-dir case still short-circuits.
        [[ -e "$entry" || -L "$entry" ]] || continue
        check_top_level_entry "$entry"
    done

    [[ -f "$specs_dir/CLAUDE.md" ]] ||
        FINDINGS+=("$specs_dir/CLAUDE.md: MISSING_CLAUDE_MD required whenever .specs/ exists")
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    local specs_dir="${1:-$REPO_ROOT/.specs}"

    if [[ ! -d "$specs_dir" ]]; then
        print_status "success" "No $specs_dir to audit."
        exit 0
    fi

    check_specs_dir "$specs_dir"

    if ((${#FINDINGS[@]} == 0)); then
        print_status "success" "Specs structure gate: aligned -- $specs_dir checked."
        exit 0
    fi

    print_status "error" "Specs structure gate: ${#FINDINGS[@]} finding(s)."
    local f
    for f in "${FINDINGS[@]}"; do
        print_status "error" "$f"
    done
    exit 1
}

main "$@"
