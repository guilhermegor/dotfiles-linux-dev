#!/usr/bin/env bats
#
# dotfiles-linux-dev#964: code_editors/vscode.sh pins the editor/terminal
# divider by seeding workbench.panel.size in VS Code's state.vscdb (no
# settings.json key exists for it). Tests use a temp DB, never ~/.config/Code.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    DB="$BATS_TEST_TMPDIR/state.vscdb"
    export VSCODE_STATE_DB="$DB"
    command -v sqlite3 > /dev/null || skip "sqlite3 not installed"
    sqlite3 "$DB" "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
                   INSERT INTO ItemTable VALUES ('workbench.panel.size', '1167');
                   INSERT INTO ItemTable VALUES ('workbench.panel.position', 'right');"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/code_editors/vscode.sh"
    pgrep() { return 1; }
}

panel_size() {
    sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key='workbench.panel.size'"
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

@test "pin_panel_divider rejects a non-integer PANEL_DIVIDER_PX" {
    PANEL_DIVIDER_PX="1'); DROP TABLE ItemTable;--" run pin_panel_divider
    [ "$status" -eq 0 ]
    [ "$(panel_size)" = "1167" ]
    PANEL_DIVIDER_PX=113px run pin_panel_divider
    [ "$(panel_size)" = "1167" ]
}

@test "pin_panel_divider skips when the panel is not on the right" {
    sqlite3 "$DB" "UPDATE ItemTable SET value='bottom' WHERE key='workbench.panel.position'"
    run pin_panel_divider
    [ "$status" -eq 0 ]
    [ "$(panel_size)" = "1167" ]
}

@test "pin_panel_divider skips when the panel position is unreadable" {
    sqlite3 "$DB" "DELETE FROM ItemTable WHERE key='workbench.panel.position'"
    run pin_panel_divider
    [ "$(panel_size)" = "1167" ]
}

@test "pin_panel_divider skips while VS Code runs, even with VSCODE_STATE_DB set" {
    pgrep() { return 0; }
    run pin_panel_divider
    [ "$status" -eq 0 ]
    [ "$(panel_size)" = "1167" ]
}

@test "pin_panel_divider warns without failing when the write fails" {
    sqlite3 "$DB" "DROP TABLE ItemTable; CREATE TABLE ItemTable (k TEXT)"
    run pin_panel_divider
    [ "$status" -eq 0 ]
}

@test "main calls pin_panel_divider" {
    run sed -n '/^main() {/,/^}/p' "$REPO_ROOT/code_editors/vscode.sh"
    [[ "$output" == *"pin_panel_divider"* ]]
}
