#!/usr/bin/env bats
#
# Unit test for the Python cache rules in .gitignore (dotfiles-linux-dev#541): the four
# Python hooks under ai_clients/claude/hooks/lib/ run every session and leave
# __pycache__/ behind, which the Stop guard and SubagentStop sweep then flag as
# uncommitted work. This pins the rule so a future template refresh (the file is
# generated from toptal's gitignore.io API) cannot silently drop it again.
#
# Run locally: bats tests/   (install with: sudo apt-get install -y bats)

setup() {
    GITIGNORE="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/.gitignore"
}

@test ".gitignore ignores __pycache__/" {
    run grep -qxF '__pycache__/' "$GITIGNORE"
    [ "$status" -eq 0 ]
}

@test ".gitignore ignores compiled Python files (*.py[cod])" {
    run grep -qxF '*.py[cod]' "$GITIGNORE"
    [ "$status" -eq 0 ]
}
