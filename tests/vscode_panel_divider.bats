#!/usr/bin/env bats
#
# dotfiles-linux-dev#964: code_editors/vscode.sh pins the editor/terminal
# divider by seeding workbench.panel.size in VS Code's state.vscdb (no
# settings.json key exists for it). Tests use a temp DB, never ~/.config/Code.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    DB="$BATS_TEST_TMPDIR/state.vscdb"
    export VSCODE_STATE_DB="$DB"
    sqlite3 "$DB" "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
                   INSERT INTO ItemTable VALUES ('workbench.panel.size', '1167');"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/code_editors/vscode.sh"
}

@test "pin_panel_divider seeds 113 px over a hand-dragged size" {
    run pin_panel_divider
    [ "$status" -eq 0 ]
    [ "$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key='workbench.panel.size'")" = "113" ]
    [ "$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key='workbench.panel.lastNonMaximizedWidth'")" = "113" ]
}

@test "pin_panel_divider honours PANEL_DIVIDER_PX" {
    PANEL_DIVIDER_PX=200 run pin_panel_divider
    [ "$status" -eq 0 ]
    [ "$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key='workbench.panel.size'")" = "200" ]
}

@test "pin_panel_divider is a no-op when state.vscdb does not exist" {
    rm "$DB"
    run pin_panel_divider
    [ "$status" -eq 0 ]
    [ ! -e "$DB" ]
}

@test "main invokes pin_panel_divider" {
    run grep -c '^    pin_panel_divider$' "$REPO_ROOT/code_editors/vscode.sh"
    [ "$output" = "1" ]
}
