#!/usr/bin/env bats
#
# Invariant for the two registry-driven installers (dotfiles-linux-dev#339): an `install_*` function
# must never prompt. The mode menu in the orchestrator (`install_programs.sh` /
# `install_coding.sh`) is the operator's consent -- once an entry is selected, it runs to
# completion without asking anything else.
#
# Why: `make run` drives both orchestrators unattended via lib/run_chain.sh. Thirty-odd prompts
# had accumulated inside the category libs asking things whose answer never varied ("update to
# latest?", "install globally?", "npm or Homebrew?"), so a setup run could not be left alone.
# Worse, a prompt inside a lib blocks with no timeout: the run just sits there.
#
# The related hazard this does NOT cover is a vendor installer that goes interactive on its own
# (the Qwen script's `exec qwen`). Nothing in this repo's text can detect that; the defence there
# is redirecting stdin at the call site, asserted separately below.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# An interactive read: `read [-r] VAR` with no input redirection, or any `read -p`/`-rp` prompt.
# `while IFS= read -r x < file` and here-string loops are data reads, not prompts, so the
# pattern deliberately requires the read to be the whole statement.
interactive_reads_in() {
    grep -nE '^[[:space:]]*read[[:space:]]+(-r[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$|^[[:space:]]*read[[:space:]].*-r?p[[:space:]]' "$1" || true
}

@test "no install_* category lib prompts the operator" {
    local offenders="" f
    for f in "$REPO_ROOT"/distro_config/install_lib/*.sh \
             "$REPO_ROOT"/distro_config/install_coding_lib/*.sh; do
        [ -f "$f" ] || continue
        local hits
        hits="$(interactive_reads_in "$f")"
        [ -z "$hits" ] || offenders+="${f#"$REPO_ROOT"/}:$hits"$'\n'
    done

    if [ -n "$offenders" ]; then
        printf 'a prompt inside an install lib blocks the unattended run (see #339):\n%s' "$offenders"
        return 1
    fi
}

@test "the orchestrator mode menus still read a choice" {
    # The counterweight to the test above: removing every prompt must not have removed the
    # one legitimate question, or 'Custom Installation' silently stops working.
    local f
    for f in distro_config/install_programs.sh distro_config/install_coding.sh; do
        grep -qE '^[[:space:]]*read -r choice' "$REPO_ROOT/$f"
        grep -qE '^[[:space:]]*read -r selection' "$REPO_ROOT/$f"
    done
}

@test "the Qwen vendor installer cannot take the terminal" {
    # Its own last line is `exec qwen`, and its parser rejects any opt-out flag, so the call
    # site must hand it a closed stdin.
    local line
    line="$(grep -A3 'install-qwen.sh' "$REPO_ROOT/distro_config/install_coding_lib/ai_clients.sh" \
        | grep -E '^\s*-s --source' || true)"
    [ -n "$line" ]
    [[ "$line" == *"< /dev/null"* ]]
}

@test "the CodeRabbit vendor installer skips its sign-in prompt" {
    # It prompts on stdin and falls back to /dev/tty, so a closed stdin alone still hangs;
    # CI=1 is the script's own switch to skip the prompt.
    local line
    line="$(grep -E 'run_or_echo .*install\.sh' "$REPO_ROOT/distro_config/install_coding_lib/vcs.sh" || true)"
    [ -n "$line" ]
    [[ "$line" == *"CI=1"* ]]
    [[ "$line" == *"< /dev/null"* ]]
}

@test "npm multi-version install reads npm's exit status, not tee's" {
    # `if run_or_echo ... | tee` reports tee's status (always 0), so every Node version was
    # reported installed -- including ones nvm had never installed.
    local fn
    fn="$(sed -n '/^npm_global_install_all_nvm_versions()/,/^}/p' \
        "$REPO_ROOT/distro_config/install_coding_lib/languages.sh")"
    [[ "$fn" == *'PIPESTATUS[0]'* ]]
    [[ "$fn" != *'if run_or_echo nvm exec'* ]]
}
