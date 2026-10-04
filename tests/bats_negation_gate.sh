#!/bin/bash
#
# tests/bats_negation_gate.sh
#
# CI gate (dotfiles-linux-dev#380): fails on any bare `! <cmd>` statement inside a
# `@test` body in tests/*.bats. bash exempts a `!`-inverted command from
# `set -e`, so such a line is not an assertion unless it happens to be the
# test's very last executed statement -- and "it is last today" is exactly
# the property that silently stops being true the moment someone appends
# another assertion below it. No last-line exemption on purpose: convert to
# `run <cmd>; [ "$status" -ne 0 ]` (or a per-suite refute_* helper) instead --
# see tests/roadmap_unblock.bats' refute_gh for the shape.
#
# A `@test "..." {` line opens a body; the close is the next line that is
# exactly `}` with no leading whitespace. Every test/function in this repo's
# tests/*.bats closes at column 0 (verified: all 547 `@test` lines end in
# `{` on the same line), so that boundary is reliable without a full shell
# parser.
#
# Usage:
#   tests/bats_negation_gate.sh [file ...]
#   (no file given -> every tests/*.bats)
#
# Run locally: bash tests/bats_negation_gate.sh
# Wired into CI via .github/workflows/tests.yml (bats_negation_gate job) and
# into `make test` so it fails locally first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

BAD_PATTERN='^[[:space:]]*![[:space:]]+[^[:space:]]'
FINDINGS=()

# Scan one .bats file for BAD_PATTERN inside @test bodies only.
scan_file() {
    local file="$1" in_test=0 lineno=0 line
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        if [ "$in_test" -eq 0 ]; then
            [[ "$line" =~ ^@test.*\{[[:space:]]*$ ]] && in_test=1
            continue
        fi
        if [[ "$line" == "}" ]]; then
            in_test=0
            continue
        fi
        if [[ "$line" =~ $BAD_PATTERN ]]; then
            FINDINGS+=("$file:$lineno: bare '! <cmd>' inside a @test body -- not an\
 assertion unless it is the test's last statement (issue #380); use\
 run <cmd>; [ \"\$status\" -ne 0 ] or a refute_* helper instead")
        fi
    done < "$file"
}

default_files() {
    find "$SCRIPT_DIR" -maxdepth 1 -name '*.bats' | sort
}

main() {
    local -a files=("$@")
    if [ "${#files[@]}" -eq 0 ]; then
        mapfile -t files < <(default_files)
    fi

    local f
    for f in "${files[@]}"; do
        scan_file "$f"
    done

    if [ "${#FINDINGS[@]}" -eq 0 ]; then
        print_status "success" "bats negation gate: clean -- ${#files[@]} file(s)\
 checked, no bare '! <cmd>' in any @test body."
        exit 0
    fi

    print_status "error" "bats negation gate: ${#FINDINGS[@]} finding(s)."
    for f in "${FINDINGS[@]}"; do
        print_status "error" "$f"
    done
    exit 1
}

main "$@"
