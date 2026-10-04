#!/bin/bash
#
# tests/validate_contracts.sh
#
# Static contract checks for ai_clients/claude artifacts — pure parse-and-assert,
# no dependencies beyond the repo. Makes the invariants documented in
# ai_clients/CLAUDE.md executable so authoring mistakes fail in CI, not silently.
#
# Run locally:  bash tests/validate_contracts.sh
# Wired into CI via .github/workflows/tests.yml (contracts job).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

CLAUDE_DIR="$REPO_ROOT/ai_clients/claude"
FAILURES=0

# A file is a real artifact only if it opens with YAML frontmatter (`---`).
# Files like skills/py-standards.md are shared reference docs with no frontmatter
# and are intentionally skipped.
_has_frontmatter() {
    [[ "$(head -1 "$1")" == "---" ]]
}

# First value of a top-level `key:` line in a file (empty if absent).
_frontmatter_value() {
    local key="$1" file="$2"
    grep -m1 "^${key}:" "$file" | sed "s/^${key}:[[:space:]]*//" || true
}

# Check 1: name: prefix matches the artifact's directory (c:/a:/s:).
check_name_prefixes() {
    print_status "info" "Checking name: prefixes..."
    local pair dir prefix f name
    for pair in "commands:c:" "agents:a:" "skills:s:"; do
        dir="${pair%%:*}"
        prefix="${pair#*:}"
        for f in "$CLAUDE_DIR/$dir"/*.md; do
            [ -e "$f" ] || continue
            _has_frontmatter "$f" || continue
            name="$(_frontmatter_value name "$f")"
            if [[ "$name" != "${prefix}"* ]]; then
                print_status "error" "$(basename "$f"): name '$name' must start with '$prefix'"
                FAILURES=$((FAILURES + 1))
            fi
        done
    done
}

# Check 2: agent model is one of the allowed values.
check_agent_models() {
    print_status "info" "Checking agent model values..."
    local f model
    for f in "$CLAUDE_DIR/agents"/*.md; do
        [ -e "$f" ] || continue
        _has_frontmatter "$f" || continue
        model="$(_frontmatter_value model "$f")"
        case "$model" in
            sonnet | opus | haiku) ;;
            *)
                print_status "error" "$(basename "$f"): model '$model' not in {sonnet,opus,haiku}"
                FAILURES=$((FAILURES + 1))
                ;;
        esac
    done
}

# Check 3: allowed-tools must never use the over-broad Bash(*) pattern.
check_no_broad_bash() {
    print_status "info" "Checking for forbidden Bash(*)..."
    local hits f
    if hits="$(grep -rln 'Bash(\*)' "$CLAUDE_DIR" 2>/dev/null)"; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            print_status "error" "$(basename "$f"): uses forbidden over-broad Bash(*)"
            FAILURES=$((FAILURES + 1))
        done <<< "$hits"
    fi
}

# Check 4: git merge-base examples must compare against the remote ref, never a bare
# base-branch placeholder (dotfiles-linux-dev#229). A stale local tracking branch silently
# mis-scopes the diff the same way an implicit HEAD does — measured as a 16-tag gap
# between `git describe` (implicit HEAD) and `git describe origin/main`. Narrowly scoped
# to this one known-fixed anti-pattern (not a general "every git command needs a ref"
# grep) because that broader form false-positives on legitimate bare-HEAD reads like
# `git log --oneline -5` or `git rev-parse HEAD` that never compare against a base.
check_merge_base_qualifies_ref() {
    print_status "info" "Checking git merge-base examples name origin/<base>, not a bare base..."
    local hits f
    if hits="$(grep -rlE 'git merge-base ["'"'"'\`]?<base' "$CLAUDE_DIR" 2>/dev/null)"; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            print_status "error" "$(basename "$f"): git merge-base compares against a bare base, not origin/<base> (dotfiles-linux-dev#229)"
            FAILURES=$((FAILURES + 1))
        done <<< "$hits"
    fi
}

# TODO(you): add the stricter contract checks below. Each is documented in
# ai_clients/CLAUDE.md but NOT yet enforced — calibrate against the current tree
# first so a legitimate exception does not turn CI red:
#
#   - skills: description should start with "Use when". NOTE: 10 py-* skills do
#     NOT today (they are a family sharing py-standards.md) — decide whether
#     they are intentional exceptions before enabling this check.
#   - filename (without .md) should equal the name: field minus its prefix.
#   - commands/skills must declare a non-empty allowed-tools field.
#   - STEPS array in ai_clients/claude/main.sh: every "key|label" has a matching
#     case branch in dispatch_step().
#   - INSTALL_REGISTRY: gnome_folder ∈ the allowed set (the func-defined check is
#     already covered by the install-smoke workflow's validate_registry run).

main() {
    check_name_prefixes
    check_agent_models
    check_no_broad_bash
    check_merge_base_qualifies_ref

    if ((FAILURES > 0)); then
        print_status "error" "Contract validation failed: $FAILURES issue(s)."
        exit 1
    fi
    print_status "success" "All contract checks passed."
}

main "$@"
