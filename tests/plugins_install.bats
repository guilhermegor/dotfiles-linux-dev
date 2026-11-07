#!/usr/bin/env bats
#
# promote_plugin_to_user_scope (dotfiles-linux-dev#932): a missing cache is
# installed through `claude plugin install --scope user`. `claude` is a PATH stub.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    CLAUDE_DIR="$TMP/claude"
    mkdir -p "$CLAUDE_DIR/plugins" "$TMP/bin"
    export CLAUDE_DIR TMP LOG_FILE="$TMP/log"
    export PATH="$TMP/bin:$PATH"
    print_status() { echo "$1: $2"; }
    # shellcheck source=../ai_clients/claude/lib/plugins.sh
    source "$REPO_ROOT/ai_clients/claude/lib/plugins.sh"
}

teardown() {
    rm -rf "$TMP"
}

# Stub claude: records its args; exits with $1, writing a user-scope entry on 0
# like the real CLI does.
stub_claude() {
    cat > "$TMP/bin/claude" <<STUB
#!/bin/bash
echo "\$*" >> "$TMP/calls"
[ "$1" -eq 0 ] || exit "$1"
f="$CLAUDE_DIR/plugins/installed_plugins.json"
[ -f "\$f" ] || echo '{"plugins":{}}' > "\$f"
jq '.plugins["foo@mkt"] = [{scope:"user",version:"1"}]' "\$f" > "$TMP/x" \\
    && mv "$TMP/x" "\$f"
STUB
    chmod +x "$TMP/bin/claude"
}

@test "install success: runs claude plugin install and records user scope" {
    stub_claude 0
    run promote_plugin_to_user_scope "foo@mkt" foo mkt
    [ "$status" -eq 0 ]
    grep -q "plugin install foo@mkt --scope user" "$TMP/calls"
    [ "$(wc -l < "$TMP/calls")" -eq 1 ]
    [[ "$output" != *"Already at user scope"* ]]
    [ "$(jq -r '.plugins["foo@mkt"][0].scope' "$CLAUDE_DIR/plugins/installed_plugins.json")" = user ]
}

@test "install failure: warns and returns 0" {
    stub_claude 1
    echo '{"plugins":{}}' > "$CLAUDE_DIR/plugins/installed_plugins.json"
    run promote_plugin_to_user_scope "foo@mkt" foo mkt
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude plugin install failed"* ]]
    [[ "$output" == *"Cache missing"* ]]
}

# Run the function with a PATH holding only jq and bash, so a real `claude`
# installed anywhere on the host can never be reached.
run_without_claude() {
    mkdir -p "$TMP/nobin"
    ln -sf "$(command -v jq)" "$TMP/nobin/jq"
    run env PATH="$TMP/nobin" CLAUDE_DIR="$CLAUDE_DIR" "$(command -v bash)" -c "
        print_status() { echo \"\$1: \$2\"; }
        source '$REPO_ROOT/ai_clients/claude/lib/plugins.sh'
        promote_plugin_to_user_scope foo@mkt foo mkt"
}

@test "claude absent: warns and returns 0" {
    echo '{"plugins":{}}' > "$CLAUDE_DIR/plugins/installed_plugins.json"
    run_without_claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cache missing"* ]]
}

@test "claude absent and no installed_plugins.json: warns, creates nothing" {
    run_without_claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude CLI absent"* ]]
    [ ! -e "$CLAUDE_DIR/plugins/installed_plugins.json" ]
}

@test "install failure with no installed_plugins.json: no skeleton left" {
    stub_claude 1
    run promote_plugin_to_user_scope "foo@mkt" foo mkt
    [ "$status" -eq 0 ]
    [ ! -e "$CLAUDE_DIR/plugins/installed_plugins.json" ]
}

@test "already at user scope: no install call" {
    stub_claude 0
    echo '{"plugins":{"foo@mkt":[{"scope":"user"}]}}' > "$CLAUDE_DIR/plugins/installed_plugins.json"
    run promote_plugin_to_user_scope "foo@mkt" foo mkt
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/calls" ]
}

@test "cache missing, file present, install succeeds: one call, no warning" {
    stub_claude 0
    echo '{"plugins":{}}' > "$CLAUDE_DIR/plugins/installed_plugins.json"
    run promote_plugin_to_user_scope "foo@mkt" foo mkt
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$TMP/calls")" -eq 1 ]
    [[ "$output" != *"warning"* ]]
}

@test "install fails but creates the file: CLI is not run twice" {
    cat > "$TMP/bin/claude" <<STUB
#!/bin/bash
echo "\$*" >> "$TMP/calls"
echo '{"plugins":{}}' > "$CLAUDE_DIR/plugins/installed_plugins.json"
exit 1
STUB
    chmod +x "$TMP/bin/claude"
    run promote_plugin_to_user_scope "foo@mkt" foo mkt
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$TMP/calls")" -eq 1 ]
    [[ "$output" == *"Cache missing"* ]]
}
