#!/usr/bin/env bats
#
# A cached verdict written by the PREVIOUS version of a hook's logic must not be replayable
# after a deploy replaces that logic (dotfiles-dev#504). install_hooks() must clear
# $CLAUDE_CONFIG_DIR/open-threads-nudge/ every time it runs, regardless of whether the cache
# existed before the deploy.
#
# Exercises install_hooks() against a TEMPORARY CLAUDE_DIR only -- never the real ~/.claude/.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    HOOKS_LIB="$REPO_ROOT/ai_clients/claude/lib/hooks.sh"
    CLAUDE_HOME="$BATS_TEST_TMPDIR/claude-home"
    mkdir -p "$CLAUDE_HOME"
}

@test "a stale cache entry does not survive a deploy" {
    mkdir -p "$CLAUDE_HOME/open-threads-nudge"
    echo '{"ts":1,"number":"1","status":"running","detail":"pre-deploy verdict"}' \
        > "$CLAUDE_HOME/open-threads-nudge/some-session.json"

    run bash -c "
        print_status() { :; }
        CLAUDE_DIR='$CLAUDE_HOME'
        source '$HOOKS_LIB'
        install_hooks
    "
    [ "$status" -eq 0 ]
    [ ! -d "$CLAUDE_HOME/open-threads-nudge" ]
}

@test "no cache present is not an error" {
    run bash -c "
        print_status() { :; }
        CLAUDE_DIR='$CLAUDE_HOME'
        source '$HOOKS_LIB'
        install_hooks
    "
    [ "$status" -eq 0 ]
    [ ! -d "$CLAUDE_HOME/open-threads-nudge" ]
}

@test "a deploy still installs the hooks themselves alongside the cache clear" {
    mkdir -p "$CLAUDE_HOME/open-threads-nudge"
    echo '{"ts":1}' > "$CLAUDE_HOME/open-threads-nudge/some-session.json"

    run bash -c "
        print_status() { :; }
        CLAUDE_DIR='$CLAUDE_HOME'
        source '$HOOKS_LIB'
        install_hooks
    "
    [ "$status" -eq 0 ]
    [ -f "$CLAUDE_HOME/hooks/open_review_threads_nudge.sh" ]
    [ ! -d "$CLAUDE_HOME/open-threads-nudge" ]
}

@test "invalidate_hook_caches leaves an unrelated directory alone" {
    mkdir -p "$CLAUDE_HOME/some-other-dir"
    echo "keep me" > "$CLAUDE_HOME/some-other-dir/file.txt"

    run bash -c "
        print_status() { :; }
        CLAUDE_DIR='$CLAUDE_HOME'
        source '$HOOKS_LIB'
        invalidate_hook_caches
    "
    [ "$status" -eq 0 ]
    [ -f "$CLAUDE_HOME/some-other-dir/file.txt" ]
}
