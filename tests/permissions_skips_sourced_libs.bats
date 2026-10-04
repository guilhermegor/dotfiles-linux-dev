#!/usr/bin/env bats
#
# Invariant for `make permissions` (dotfiles-linux-dev#312): four sourced libraries
# (ai_clients/claude/lib/profiles.sh, ai_clients/claude/hooks/lib/review_thread_gate.sh,
# ai_clients/claude/lib/shared_agents_md.sh, ai_clients/claude/profile_functions.sh) are stored
# 100644 in git because nothing execs them directly -- only `source`. `make permissions` chmodding
# them to 755 dirties the tree on every run and, for three of them, falsely advertised an unguarded
# sourced-only file as safe to run directly.
#
# Runs the REAL `permissions:` recipe from the repo Makefile (via `make -C <fixture> -f
# <repo-Makefile>`) against a throwaway fixture tree that mirrors the repo's directory shape --
# never against the real repo, so this test cannot chmod anything under version control.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MAKEFILE="$REPO_ROOT/Makefile"
    FIXTURE="$(mktemp -d)"

    mkdir -p "$FIXTURE"/distro_config "$FIXTURE"/drivers "$FIXTURE"/os "$FIXTURE"/storage "$FIXTURE"/code_editors
    mkdir -p "$FIXTURE"/ai_clients/claude/lib
    mkdir -p "$FIXTURE"/ai_clients/claude/hooks/lib
    mkdir -p "$FIXTURE"/ai_clients/lib
    mkdir -p "$FIXTURE"/ai_clients/codex/lib

    # Entry points: `permissions` must still make these executable.
    for f in \
        "$FIXTURE/distro_config/install_thing.sh" \
        "$FIXTURE/ai_clients/main.sh" \
        "$FIXTURE/ai_clients/claude/main.sh" \
        "$FIXTURE/ai_clients/claude/hooks/some_hook.sh"
    do
        printf '#!/bin/bash\n' >"$f"
        chmod 644 "$f"
    done

    # Sourced-only libraries: `permissions` must leave these at 644.
    for f in \
        "$FIXTURE/ai_clients/claude/lib/profiles.sh" \
        "$FIXTURE/ai_clients/claude/hooks/lib/review_thread_gate.sh" \
        "$FIXTURE/ai_clients/lib/utils.sh" \
        "$FIXTURE/ai_clients/codex/lib/config.sh"
    do
        printf '#!/bin/bash\n' >"$f"
        chmod 644 "$f"
    done
    printf '#!/usr/bin/env bash\n' >"$FIXTURE/ai_clients/claude/profile_functions.sh"
    chmod 644 "$FIXTURE/ai_clients/claude/profile_functions.sh"
}

teardown() {
    rm -rf "$FIXTURE"
}

mode_of() {
    stat -c '%a' "$1"
}

@test "make permissions leaves sourced libs (*/lib/* + profile_functions.sh) at 644" {
    run make -C "$FIXTURE" -f "$MAKEFILE" permissions
    [ "$status" -eq 0 ]

    [ "$(mode_of "$FIXTURE/ai_clients/claude/lib/profiles.sh")" = "644" ]
    [ "$(mode_of "$FIXTURE/ai_clients/claude/hooks/lib/review_thread_gate.sh")" = "644" ]
    [ "$(mode_of "$FIXTURE/ai_clients/lib/utils.sh")" = "644" ]
    [ "$(mode_of "$FIXTURE/ai_clients/codex/lib/config.sh")" = "644" ]
    [ "$(mode_of "$FIXTURE/ai_clients/claude/profile_functions.sh")" = "644" ]
}

@test "make permissions still makes entry points executable" {
    run make -C "$FIXTURE" -f "$MAKEFILE" permissions
    [ "$status" -eq 0 ]

    [ "$(mode_of "$FIXTURE/distro_config/install_thing.sh")" = "755" ]
    [ "$(mode_of "$FIXTURE/ai_clients/main.sh")" = "755" ]
    [ "$(mode_of "$FIXTURE/ai_clients/claude/main.sh")" = "755" ]
    [ "$(mode_of "$FIXTURE/ai_clients/claude/hooks/some_hook.sh")" = "755" ]
}

@test "make permissions run twice is idempotent (no mode changes on the second run)" {
    make -C "$FIXTURE" -f "$MAKEFILE" permissions >/dev/null

    local before after
    before="$(find "$FIXTURE" -name '*.sh' -exec stat -c '%n %a' {} \; | sort)"
    make -C "$FIXTURE" -f "$MAKEFILE" permissions >/dev/null
    after="$(find "$FIXTURE" -name '*.sh' -exec stat -c '%n %a' {} \; | sort)"

    [ "$before" = "$after" ]
}
