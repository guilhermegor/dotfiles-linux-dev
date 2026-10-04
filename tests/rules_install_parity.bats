#!/usr/bin/env bats
#
# Parity between the rule files PRESENT in ai_clients/claude/rules/ and the rules
# INSTALLED by install_rules() in ai_clients/claude/lib/rules.sh.
#
# Why this exists (dotfiles-linux-dev#333): rules are ENUMERATED, not globbed. install_rules()
# calls one install_<lang>_rules() function per file, by name. A .md dropped into rules/
# with no matching function and no call in the dispatcher is silently never installed --
# it copies nothing, errors nothing, and simply never reaches ~/.claude/rules/. The deploy
# prints success for the rules it did copy. This is the same class of defect as
# tests/hooks_install_parity.bats (#266), one directory over.
#
# Two directions, both asserted, plus the dispatcher link:
#   1. every rules/*.md is named in a copy_rule_file call
#   2. every copy_rule_file name exists as a file
#   3. every install_<x>_rules() defined is actually CALLED from install_rules() -- a
#      function that exists but is never dispatched copies exactly nothing
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    RULES_SRC="$REPO_ROOT/ai_clients/claude/rules"
    RULES_LIB="$REPO_ROOT/ai_clients/claude/lib/rules.sh"
}

# Every <name>.md living in the rules source directory.
source_rules() {
    find "$RULES_SRC" -maxdepth 1 -name '*.md' -printf '%f\n' | sort -u
}

# Every name passed to copy_rule_file. Comment lines are stripped first: the file header
# documents the convention in prose, and a future edit adding a literal example would
# otherwise be picked up as a real call.
installed_rules() {
    grep -v '^[[:space:]]*#' "$RULES_LIB" \
        | grep -oE 'copy_rule_file[[:space:]]+"[^"]+"' \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        | sort -u
}

# Every install_<x>_rules() function DEFINED in the lib (install_rules itself excluded).
defined_installers() {
    grep -oE '^install_[a-z0-9_]+_rules\(\)' "$RULES_LIB" \
        | sed 's/()$//' \
        | grep -vx 'install_rules' \
        | sort -u
}

# Every install_<x>_rules called from inside the install_rules() body, comments stripped
# so the commented-out `# install_go_rules ...` placeholder does not count as a call.
dispatched_installers() {
    sed -n '/^install_rules()/,/^}/p' "$RULES_LIB" \
        | grep -v '^[[:space:]]*#' \
        | grep -oE 'install_[a-z0-9_]+_rules' \
        | grep -vx 'install_rules' \
        | sort -u
}

@test "rules/ holds at least one rule file (guards against a broken extractor)" {
    run source_rules
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rules.sh copies at least one rule file (guards against a broken extractor)" {
    run installed_rules
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "every rule file in rules/ is installed by rules.sh" {
    local missing=""
    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        if ! installed_rules | grep -qxF "$rule"; then
            missing="$missing $rule"
        fi
    done < <(source_rules)

    if [ -n "$missing" ]; then
        echo "Present in rules/ but never copied by install_rules():$missing"
        echo "Add an install_<name>_rules() function AND a call to it, per the"
        echo "three-step procedure in the header of ai_clients/claude/lib/rules.sh."
        return 1
    fi
}

@test "every rule copied by rules.sh exists in the source tree" {
    local absent=""
    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        [ -f "$RULES_SRC/$rule" ] || absent="$absent $rule"
    done < <(installed_rules)

    if [ -n "$absent" ]; then
        echo "copy_rule_file names a file that does not exist in rules/:$absent"
        return 1
    fi
}

@test "every install_<x>_rules function is dispatched from install_rules" {
    local orphaned=""
    while IFS= read -r fn; do
        [ -n "$fn" ] || continue
        if ! dispatched_installers | grep -qxF "$fn"; then
            orphaned="$orphaned $fn"
        fi
    done < <(defined_installers)

    if [ -n "$orphaned" ]; then
        echo "Defined but never called from install_rules():$orphaned"
        echo "A per-rule installer that is never dispatched copies nothing."
        return 1
    fi
}
