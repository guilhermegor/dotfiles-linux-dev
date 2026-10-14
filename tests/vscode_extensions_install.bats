#!/usr/bin/env bats
#
# dotfiles-linux-dev#768: install_extensions reported success while installs
# failed, and treated any id that was a substring of an installed one as
# installed. `code` is stubbed on PATH -- no real VS Code, no network.

REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/code_editors" "$BATS_TEST_TMPDIR/.vscode"
    # vscode.sh runs main() when sourced, so extract only the function; the copy sits
    # beside its own .vscode/ because the function locates extensions.txt relative to itself.
    sed -n '/^install_extensions() {/,/^}/p' "$REPO/code_editors/vscode.sh" \
        > "$BATS_TEST_TMPDIR/code_editors/fn.sh"
    cat > "$BATS_TEST_TMPDIR/bin/code" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    --list-extensions) printf '%b' "${STUB_INSTALLED:-}" ;;
    --install-extension) [[ " ${STUB_FAIL:-} " == *" $2 "* ]] && exit 1; exit 0 ;;
esac
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/code"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

run_install() {
    printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/.vscode/extensions.txt"
    run bash -c 'print_status() { echo "[$1] $2"; }
        source "$1"; install_extensions' _ "$BATS_TEST_TMPDIR/code_editors/fn.sh"
}

@test "a failing install returns non-zero and names the failed id" {
    STUB_FAIL="bad.ext" run_install "vscode:bad.ext" "vscode:good.ext"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed extensions: bad.ext"* ]]
    [[ "$output" == *"Failed: 1"* ]]
}

@test "an id that is only a prefix of an installed one is not installed" {
    STUB_INSTALLED='ms-python.python-envs\n' run_install "vscode:ms-python.python"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully installed: ms-python.python"* ]]
}

@test "match against installed extensions is case-insensitive" {
    STUB_INSTALLED='Ms-Python.Python\n' STUB_FAIL="ms-python.python" run_install "vscode:ms-python.python"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

@test "extensions.txt no longer lists the unpublished or built-in extensions" {
    run grep -iE '^(vscode:)?(codeium\.codeium|github\.copilot(-chat)?)$' "$REPO/.vscode/extensions.txt"
    [ "$status" -ne 0 ]
}
