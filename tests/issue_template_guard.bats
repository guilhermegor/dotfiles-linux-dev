#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/issue_template_guard.sh
#
# Strategy mirrors tests/pr_template_guard.bats: the hook is a stdin->exit-code filter over a
# PreToolUse JSON payload. Every test runs inside a throwaway git repo shipping a known
# .github/ISSUE_TEMPLATE/project-seed.md, modelled on guilhermegor/greenfield's real template
# (bold `·`-separated stack line, `### Definition of done` checklist, conditional `**Blocked
# by:**` gated by a `state:blocked` label via the `issue-template-guard: require ... if-label`
# directive).
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/issue_template_guard.sh"
    REPO="$(mktemp -d)"
    cd "$REPO"
    git init -q .
    mkdir -p .github/ISSUE_TEMPLATE
    cat > .github/ISSUE_TEMPLATE/project-seed.md <<'TEMPLATE'
---
name: Project seed
about: One future repository.
title: "<repo-name> — <one-line purpose>"
labels: []
---

<!--
Required, always:
  - the stack line (first line, bold, `·`-separated)
  - `### Definition of done` with at least one `- [ ]` item

Required when the issue carries the `state:blocked` label:
  - a `**Blocked by:**` line
issue-template-guard: require "**Blocked by:**" if-label state:blocked
-->

**Python · PyPI · public repo**

What this repository is.

### Definition of done
- [ ] Scaffolded
- [ ] First real module
TEMPLATE
    export -f payload   # make it visible to the `bash -c` subshells that `run` spawns
}

teardown() {
    rm -rf "$REPO"
}

payload() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

COMPLIANT_BODY='**Python · PyPI · public repo**\n\nWhat it is.\n\n### Definition of done\n- [ ] a'
NO_DOD_BODY='**Python · PyPI · public repo**\n\nNo definition of done here.'
NO_STACK_BODY='Just some text.\n\n### Definition of done\n- [ ] a'

# --- no template in the repo: untouched -------------------------------------------------------

@test "allows any body when the target repo ships no issue template" {
    rm -rf .github/ISSUE_TEMPLATE
    run bash -c "payload 'gh issue create --title x --body \"nothing structured at all\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

# --- required-always rules ----------------------------------------------------------------------

@test "blocks a body missing Definition of done, echoing the template" {
    run bash -c "payload 'gh issue create --title x --body \"$NO_DOD_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Missing required sections"* ]]
    [[ "$output" == *"Definition of done"* ]]
    [[ "$output" == *"ISSUE_TEMPLATE"* ]]
}

@test "blocks a body missing the bold stack line" {
    run bash -c "payload 'gh issue create --title x --body \"$NO_STACK_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"bold first line"* || "$output" == *"separated first line"* ]]
}

@test "passes a fully compliant body with no labels" {
    run bash -c "payload 'gh issue create --title x --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

# --- conditional Blocked-by rule -----------------------------------------------------------------

@test "blocks state:blocked labelled issue missing Blocked by" {
    run bash -c "payload 'gh issue create --label state:blocked --title x --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Blocked by"* ]]
}

@test "passes state:blocked labelled issue that has Blocked by" {
    local body='**Python · PyPI · public repo**\n\n**Blocked by:** other#1\n\n### Definition of done\n- [ ] a'
    run bash -c "payload 'gh issue create --label state:blocked --title x --body \"$body\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "passes a non-blocked issue with no Blocked-by line" {
    run bash -c "payload 'gh issue create --title x --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "fails open on gh issue edit that cannot determine the blocked label (no Blocked by)" {
    # --add-label never proves state:blocked is ABSENT — an edit that doesn't touch labels at all
    # must not be forced to add a Blocked-by line just because it happens to be missing.
    run bash -c "payload 'gh issue edit 5 --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "enforces Blocked by when gh issue edit --add-label positively adds state:blocked" {
    run bash -c "payload 'gh issue edit 5 --add-label state:blocked --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Blocked by"* ]]
}

# --- pass-through: not our concern ----------------------------------------------------------------

@test "ignores non-gh commands" {
    run bash -c "payload 'echo gh issue create --body \"nothing\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "a body mentioning gh issue create inside a commit message does not trip it" {
    run bash -c "payload 'git commit -m \"docs: mention gh issue create --body flag\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "ignores a gh issue edit with no body flag (label-only edit)" {
    run bash -c "payload 'gh issue edit 5 --add-label state:blocked' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "ignores gh pr create even with a body flag (issue guard is issue-only)" {
    run bash -c "payload 'gh pr create --title x --body \"nothing useful\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

# --- multiple templates: pass if ANY ONE is satisfied ---------------------------------------------

@test "passes when body satisfies only the second of two templates" {
    cat > .github/ISSUE_TEMPLATE/bug-report.md <<'TEMPLATE'
---
name: Bug report
---

### Steps to reproduce
- [ ] step one
TEMPLATE
    run bash -c "payload 'gh issue create --title x --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "blocks when body satisfies neither of two templates" {
    cat > .github/ISSUE_TEMPLATE/bug-report.md <<'TEMPLATE'
---
name: Bug report
---

### Steps to reproduce
- [ ] step one
TEMPLATE
    run bash -c "payload 'gh issue create --title x --body \"totally unrelated text\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Checked 2 templates"* ]]
}

# --- --repo resolution, mirroring pr_template_guard.bats's coverage ------------------------------

@test "judges a gh issue create --repo TARGET against TARGET's template, not the session cwd's" {
    local fake_home target
    fake_home="$(mktemp -d)"
    target="$fake_home/github/other-repo"
    mkdir -p "$target/.github/ISSUE_TEMPLATE"
    git init -q "$target"
    printf -- '### Sign-off\n' > "$target/.github/ISSUE_TEMPLATE/other.md"

    run env HOME="$fake_home" bash -c "payload 'gh issue create --repo someowner/other-repo --title x --body \"### Sign-off\"' | '$GUARD'"
    [ "$status" -eq 0 ]
    rm -rf "$fake_home"
}

@test "reports unresolvable (not non-compliant) when --repo has no local checkout" {
    local fake_home
    fake_home="$(mktemp -d)"
    run env HOME="$fake_home" bash -c "payload 'gh issue create --repo someowner/ghost-repo --title x --body \"whatever\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not"* ]]
    [[ "$output" != *"Missing required sections"* ]]
    rm -rf "$fake_home"
}

@test "passes when the resolved --repo target has no ISSUE_TEMPLATE of its own" {
    local fake_home target
    fake_home="$(mktemp -d)"
    target="$fake_home/github/no-template-repo"
    mkdir -p "$target"
    git init -q "$target"
    run env HOME="$fake_home" bash -c "payload 'gh issue create --repo someowner/no-template-repo --title x --body \"whatever\"' | '$GUARD'"
    [ "$status" -eq 0 ]
    rm -rf "$fake_home"
}

# --- command matching is real argv, not a start-anchored regex (CodeRabbit review, PR #371) ----

@test "catches a bad body-file chained after && (was a bypass)" {
    run bash -c "payload 'cd /tmp && gh issue create --title x --body-file $REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
}

@test "catches a bad body-file chained after ; (was a bypass)" {
    run bash -c "payload 'true; gh issue create --title x --body-file $REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
}

@test "catches a bad body-file chained after | (was a bypass)" {
    run bash -c "payload 'echo x | gh issue create --title x --body-file $REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
}

@test "a gh issue create mentioned only inside a heredoc body is not executed, not matched" {
    local cmd
    cmd="cat <<'EOF'
gh issue create --title fake --body-file $REPO/nope.md
EOF"
    run bash -c 'payload "$1" | "$2"' _ "$cmd" "$GUARD"
    [ "$status" -eq 0 ]
}

@test "an unparseable command (unbalanced quote) fails open" {
    run bash -c "payload 'gh issue create --title x --body \"unterminated' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "resolves the REAL --repo even when --title contains decoy --repo text" {
    local fake_home target
    fake_home="$(mktemp -d)"
    target="$fake_home/github/other-repo"
    mkdir -p "$target/.github/ISSUE_TEMPLATE"
    git init -q "$target"
    printf -- '### Sign-off\n' > "$target/.github/ISSUE_TEMPLATE/other.md"

    # The --title value contains "--repo someowner/decoy-repo", which the old regex-scraping
    # extract_target_repo took as the FIRST --repo match; the REAL --repo (after --title) must
    # win, resolving to `other-repo`'s Sign-off template rather than a nonexistent decoy repo.
    run env HOME="$fake_home" bash -c "payload 'gh issue create --title \"see --repo someowner/decoy-repo\" --repo someowner/other-repo --body \"### Sign-off\"' | '$GUARD'"
    [ "$status" -eq 0 ]
    rm -rf "$fake_home"
}

# --- pflag also accepts attached short flags: `-bX` and `-b=X` (dotfiles-dev#604) --------------
#
# scan_flags() used to read short flags only in the separated form, so an attached `-b`/`-F`/
# `-l`/`-R` was never seen and the guard passed the command unread (fail-open).

@test "blocks an attached -b<body> missing Definition of done" {
    run bash -c "payload 'gh issue create --title x -b\"$NO_DOD_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Missing required sections"* ]]
}

@test "blocks an -b=<body> missing Definition of done" {
    run bash -c "payload 'gh issue create --title x -b=\"$NO_DOD_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Missing required sections"* ]]
}

@test "passes a compliant -b=<body> (the = is stripped, so the bold first line still matches)" {
    run bash -c "payload 'gh issue create --title x -b=\"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "fails loud on an attached -F<missing path>" {
    run bash -c "payload 'gh issue create --title x -F$REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
}

@test "fails loud on an -F=<missing path>" {
    run bash -c "payload 'gh issue create --title x -F=$REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
}

@test "enforces Blocked by for an attached -l<label>" {
    run bash -c "payload 'gh issue create -lstate:blocked --title x --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Blocked by"* ]]
}

@test "enforces Blocked by for an -l=<label>" {
    run bash -c "payload 'gh issue create -l=state:blocked --title x --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Blocked by"* ]]
}

@test "enforces Blocked by when a comma list in an attached -l<a,b> carries state:blocked" {
    run bash -c "payload 'gh issue create -lbug,state:blocked --title x --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Blocked by"* ]]
}

@test "judges an attached -R<TARGET> against TARGET's template, not the session cwd's" {
    local fake_home target
    fake_home="$(mktemp -d)"
    target="$fake_home/github/other-repo"
    mkdir -p "$target/.github/ISSUE_TEMPLATE"
    git init -q "$target"
    printf -- '### Sign-off\n' > "$target/.github/ISSUE_TEMPLATE/other.md"

    # $REPO's own template is satisfied by this body; only the target's Sign-off is not.
    run env HOME="$fake_home" bash -c "payload 'gh issue create -Rsomeowner/other-repo --title x --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Sign-off"* ]]
    rm -rf "$fake_home"
}

@test "judges an -R=<TARGET> against TARGET's template, not the session cwd's" {
    local fake_home target
    fake_home="$(mktemp -d)"
    target="$fake_home/github/other-repo"
    mkdir -p "$target/.github/ISSUE_TEMPLATE"
    git init -q "$target"
    printf -- '### Sign-off\n' > "$target/.github/ISSUE_TEMPLATE/other.md"

    run env HOME="$fake_home" bash -c "payload 'gh issue create -R=someowner/other-repo --title x --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Sign-off"* ]]
    rm -rf "$fake_home"
}
