#!/usr/bin/env bats
#
# Unit tests for ai_clients/lib/restore_env_prompt.sh
#
# Strategy (no real restore ever runs):
#   - Stub `print_status` BEFORE sourcing the helper. The helper only sources
#     lib/common.sh when print_status is undefined, so our stub is used instead
#     and its output is captured for assertions.
#   - Override $HOME    → controls the installed-binary branch
#     ($HOME/.local/bin/restore-env.sh).
#   - Override REPO_ROOT → controls the fallback branch
#     ($REPO_ROOT/storage/restore_env.sh). The helper reads the global REPO_ROOT
#     at call time, so reassigning it after sourcing redirects the fallback.
#   - Drive the `read -rp` prompt by piping a line on stdin (`run … <<< "y"`).
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    # Stub status output BEFORE sourcing → helper skips sourcing lib/common.sh.
    print_status() { echo "[$1] $2"; }

    REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    source "$REPO_ROOT_REAL/ai_clients/lib/restore_env_prompt.sh"

    # Redirect both dispatch boundaries into a throwaway sandbox.
    TEST_TMP="$(mktemp -d)"
    HOME="$TEST_TMP/home"
    mkdir -p "$HOME/.local/bin"
    REPO_ROOT="$TEST_TMP/fakerepo"
    mkdir -p "$REPO_ROOT/storage"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ── Example test 1 (provided) ────────────────────────────────────────────────

@test "bare Enter skips when .env exists (default no)" {
    touch "$REPO_ROOT/.env"
    run prompt_restore_env <<< ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping .env restore."* ]]
}

# ── New: existence-aware default ─────────────────────────────────────────────
# When the repo-root .env is absent (fresh setup), the default flips to yes, so
# a bare Enter proceeds with the restore instead of skipping.

@test "bare Enter restores when .env is absent (default yes)" {
    cat > "$HOME/.local/bin/restore-env.sh" <<'STUB'
#!/bin/bash
echo "INSTALLED-RAN"
STUB
    chmod +x "$HOME/.local/bin/restore-env.sh"

    run prompt_restore_env <<< $'\n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALLED-RAN"* ]]
}

# ── Example test 2 (provided) ────────────────────────────────────────────────

@test "yes runs the installed binary when it is present" {
    cat > "$HOME/.local/bin/restore-env.sh" <<'STUB'
#!/bin/bash
echo "INSTALLED-RAN"
STUB
    chmod +x "$HOME/.local/bin/restore-env.sh"

    run prompt_restore_env <<< $'y\ny'
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALLED-RAN"* ]]
}

# ── TODO(you): dispatch-branch assertions ────────────────────────────────────
# These are the interesting cases — the ones where you decide what "the right
# thing happened" means. Delete the `skip` line once you've written each body.

@test "yes falls back to storage/restore_env.sh when no installed binary" {
    skip "TODO(you): write this assertion"
    # Hints (verified to work):
    #   - Do NOT create $HOME/.local/bin/restore-env.sh, so the `-x` branch is
    #     skipped and the helper falls through to the repo fallback.
    #   - The fallback is invoked with `bash "$fallback"`, so it needs to be a
    #     regular file but does NOT need the execute bit. Create it with a
    #     sentinel line, e.g.:
    #         printf '#!/bin/bash\necho FALLBACK-RAN\n' \
    #             > "$REPO_ROOT/storage/restore_env.sh"
    #   - run prompt_restore_env <<< "y"
    #   - Assert: status 0, output contains your sentinel ("FALLBACK-RAN") AND
    #     the helper's own "running repo fallback" warning line.
}

@test "yes with neither script present errors and returns 1" {
    skip "TODO(you): write this assertion"
    # Hints (verified to work):
    #   - Leave BOTH boundaries empty: no $HOME/.local/bin/restore-env.sh and no
    #     $REPO_ROOT/storage/restore_env.sh (setup() already points them at empty
    #     sandbox dirs, so you need only avoid creating either file).
    #   - run prompt_restore_env <<< "y"
    #   - Assert: status -eq 1, output contains "No restore-env script found".
}

@test "answers other than y/yes are treated as no" {
    skip "TODO(you): pick an input and assert the skip path"
    # Hints:
    #   - The accept regex is ^[Yy]([Ee][Ss])?$ — so "n", "nope", "Y E S", "1",
    #     and random text all mean NO. Choose one and confirm it skips.
    #   - run prompt_restore_env <<< "nope"
    #   - Assert: status 0, output contains "Skipping .env restore.", and does
    #     NOT attempt any dispatch.
}
