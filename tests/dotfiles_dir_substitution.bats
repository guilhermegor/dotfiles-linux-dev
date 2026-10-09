#!/usr/bin/env bats
#
# The checkout path is derived, never hardcoded (dotfiles-linux-dev#661). A tracked file that
# names the checkout writes the placeholder @DOTFILES_DIR@; the installers render it on the
# way to ~/.claude. Renaming the checkout directory is then a no-op for every tracked file.
#
# Everything here deploys into a TEMPORARY CLAUDE_DIR with DOTFILES_DIR forced to a fake path
# -- never the real ~/.claude/.
#
# Run locally:  bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    DIR_LIB="$REPO_ROOT/ai_clients/claude/hooks/lib/dotfiles_dir.sh"
    CLAUDE_HOME="$BATS_TEST_TMPDIR/claude-home"
    FAKE_DIR="$BATS_TEST_TMPDIR/some where/renamed-checkout"
    mkdir -p "$CLAUDE_HOME"
}

# Deploy the four placeholder-bearing artifact types into the temp CLAUDE_DIR.
deploy_all() {
    run env DOTFILES_DIR="$FAKE_DIR" CLAUDE_HOME="$CLAUDE_HOME" REPO_ROOT="$REPO_ROOT" bash -c '
        print_status() { :; }
        CLAUDE_DIR="$CLAUDE_HOME"
        SCRIPT_DIR="$REPO_ROOT/ai_clients/claude"
        source "$SCRIPT_DIR/lib/hooks.sh"
        source "$SCRIPT_DIR/lib/skills.sh"
        source "$SCRIPT_DIR/lib/claude_md.sh"
        source "$SCRIPT_DIR/lib/settings.sh"
        install_hooks && install_skills && install_claude_md && configure_settings
    '
}

# ── the invariant ────────────────────────────────────────────────────────────

@test "no tracked file outside docs/history hardcodes the checkout path" {
    # Pattern is a regex so this file does not match itself. Bare NAMES (dotfiles-dev#68,
    # "Origin: dotfiles-dev") are fine: a rename does not break a label, only a path.
    # github-dotfiles-dev is the same path in Claude's project-key spelling.
    run git -C "$REPO_ROOT" grep -n -I -E 'github[/-]dotfiles-dev' -- \
        ':(exclude)docs' ':(exclude).specs' ':(exclude)CHANGELOG*' ':(exclude)tests/dotfiles_dir_substitution.bats'
    # git grep exits 1 on no match; anything else (0 = a hit, 128 = error) must fail the test
    [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "the placeholder only appears in artifacts that an installer renders" {
    # rules/, commands/, agents/, shared/ and the other clients are copied verbatim, so a
    # placeholder there would reach the live config unrendered.
    run git -C "$REPO_ROOT" grep -l -I '@DOTFILES_DIR@' -- \
        'ai_clients/claude/rules' 'ai_clients/claude/commands' 'ai_clients/claude/agents' \
        'ai_clients/shared' 'ai_clients/codex' 'ai_clients/qwen' 'ai_clients/copilot' 'ai_clients/kimi'
    [ "$status" -eq 1 ] || { echo "$output"; false; }
}

# ── deploy renders it ────────────────────────────────────────────────────────

@test "a deploy leaves no placeholder anywhere under CLAUDE_DIR" {
    deploy_all
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run grep -rl '@DOTFILES_DIR@' "$CLAUDE_HOME"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "the source-guard redirect names the resolved checkout" {
    deploy_all
    [ "$status" -eq 0 ]
    grep -qF "  $FAKE_DIR/" "$CLAUDE_HOME/hooks/claude_artifact_source_guard.sh"
}

@test "settings.json additionalDirectories gets the resolved checkout" {
    deploy_all
    [ "$status" -eq 0 ]
    run jq -r '.permissions.additionalDirectories[]' "$CLAUDE_HOME/settings.json"
    [[ "$output" == *"$FAKE_DIR"* ]]
}

@test "the global CLAUDE.md names the resolved checkout" {
    deploy_all
    [ "$status" -eq 0 ]
    grep -qF "$FAKE_DIR/ai_clients/claude/" "$CLAUDE_HOME/CLAUDE.md"
}

@test "a hook without a placeholder is installed byte-for-byte and stays executable" {
    deploy_all
    [ "$status" -eq 0 ]
    cmp "$REPO_ROOT/ai_clients/claude/hooks/commit_secret_guard.sh" "$CLAUDE_HOME/hooks/commit_secret_guard.sh"
    [ -x "$CLAUDE_HOME/hooks/claude_artifact_source_guard.sh" ]
}

@test "a failed resolve leaves the previous live file intact" {
    printf 'old live\n' > "$CLAUDE_HOME/out.md"
    printf 'dir=@DOTFILES_DIR@\n' > "$BATS_TEST_TMPDIR/src.md"
    # not a git repo and no override: nothing to resolve from
    run env -u DOTFILES_DIR bash -c "
        source '$DIR_LIB'
        resolve_dotfiles_dir '$BATS_TEST_TMPDIR/not-a-repo'
    "
    [ "$status" -ne 0 ]
    run env -u DOTFILES_DIR bash -c "
        source '$DIR_LIB'
        resolve_dotfiles_dir() { return 1; }
        install_with_dotfiles_dir '$BATS_TEST_TMPDIR/src.md' '$CLAUDE_HOME/out.md'
    "
    [ "$status" -ne 0 ]
    [ "$(cat "$CLAUDE_HOME/out.md")" = "old live" ]
    [ -z "$(ls "$CLAUDE_HOME" | grep -v '^out.md$')" ]   # no temp file left behind
}

# ── the helper itself ────────────────────────────────────────────────────────

@test "substitute_dotfiles_dir treats sed metacharacters in the path literally" {
    run bash -c "
        source '$DIR_LIB'
        printf 'x @DOTFILES_DIR@ y\n' | substitute_dotfiles_dir '/a&b|c\\d'
    "
    [ "$status" -eq 0 ]
    [ "$output" = 'x /a&b|c\d y' ]
}

@test "resolve_dotfiles_dir honours DOTFILES_DIR over git" {
    run env DOTFILES_DIR=/override bash -c "source '$DIR_LIB'; resolve_dotfiles_dir"
    [ "$output" = "/override" ]
}

@test "resolve_dotfiles_dir returns the MAIN checkout from inside a linked worktree" {
    local main="$BATS_TEST_TMPDIR/main-checkout" wt="$BATS_TEST_TMPDIR/agent-worktree"
    git init -q "$main"
    git -C "$main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    git -C "$main" worktree add -q "$wt" -b wt-branch

    run env -u DOTFILES_DIR bash -c "source '$DIR_LIB'; resolve_dotfiles_dir '$wt'"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cd "$main" && pwd -P)" ] || [ "$output" = "$main" ]
}

# ── drift detection agrees with the installer ───────────────────────────────

@test "deploy_drift reads a correctly rendered deploy as clean and a raw copy as drift" {
    local root="$BATS_TEST_TMPDIR/repo" live="$BATS_TEST_TMPDIR/live"
    mkdir -p "$root/ai_clients/claude/skills" "$live/skills/s"
    printf 'edit @DOTFILES_DIR@/ai_clients/claude/\n' > "$root/ai_clients/claude/skills/s.md"

    printf 'edit %s/ai_clients/claude/\n' "$FAKE_DIR" > "$live/skills/s/SKILL.md"
    run env DOTFILES_DIR="$FAKE_DIR" bash -c "source '$REPO_ROOT/ai_clients/claude/hooks/lib/deploy_drift.sh'; deploy_drift_counts '$root' '$live'"
    [ "$output" = "$(printf '0\t0')" ]

    printf 'edit @DOTFILES_DIR@/ai_clients/claude/\n' > "$live/skills/s/SKILL.md"
    run env DOTFILES_DIR="$FAKE_DIR" bash -c "source '$REPO_ROOT/ai_clients/claude/hooks/lib/deploy_drift.sh'; deploy_drift_counts '$root' '$live'"
    [ "$output" = "$(printf '1\t0')" ]
}

@test "the deployed helper still substitutes (deploy renders hooks/lib/ too)" {
    deploy_all
    [ "$status" -eq 0 ]
    run bash -c 'source "$1"; printf "x @DOTFILES_DIR""@ y\n" | substitute_dotfiles_dir /new/path' _ \
        "$CLAUDE_HOME/hooks/lib/dotfiles_dir.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "x /new/path y" ]
}
