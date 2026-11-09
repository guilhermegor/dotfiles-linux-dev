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

@test "uses the cwd checkout when its origin names --repo, even if the dir name differs (#701)" {
    local fake_home
    fake_home="$(mktemp -d)"   # empty: the $HOME/github/<name> fallback cannot resolve
    git remote add origin https://github.com/someowner/other-repo.git
    run env HOME="$fake_home" bash -c "payload 'gh issue create --repo someowner/other-repo --title x --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 0 ]
    rm -rf "$fake_home"
}

@test "still blocks as unresolved when the cwd origin names a different repo (#701)" {
    local fake_home
    fake_home="$(mktemp -d)"
    git remote add origin git@github.com:someowner/not-the-target.git
    run env HOME="$fake_home" bash -c "payload 'gh issue create --repo someowner/other-repo --title x --body \"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not resolve"* ]]
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

# --- pflag also accepts attached short flags: `-bX` and `-b=X` (dotfiles-linux-dev#604) --------------
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

# --- #931: the completeness check is one shared helper, never a second copy ----------------------

@test "the guard takes evaluate_template from issue_spec_complete.sh, defining none itself" {
    local hooks="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks"
    grep -q 'lib/issue_spec_complete.sh' "$hooks/issue_template_guard.sh"
    run grep -E '^(evaluate_template|section_has_checklist|strip_frontmatter_and_comments)\(\)' \
        "$hooks/issue_template_guard.sh"
    [ "$status" -ne 0 ]
    grep -q '^evaluate_template()' "$hooks/lib/issue_spec_complete.sh"
}

@test "section lookup: whole heading only, and a ### subsection stays inside its ## section" {
    local lib="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/issue_spec_complete.sh"
    run bash -c "source '$lib'; _spec_section \"\$(printf '## Out of scope\n\nx\n')\" Scope"
    [ "$status" -ne 0 ]
    run bash -c "source '$lib'; spec_section_filled \"\$(printf '## Scope\n\n### Part\n\ntext\n\n## Next\n')\" Scope"
    [ "$status" -eq 0 ]
    run bash -c "source '$lib'; spec_section_filled \"\$(printf '## Scope\n\n\`\`\`\n## fake\n\`\`\`\n')\" Scope"
    [ "$status" -eq 0 ]
}

@test "section lookup: UTF-8 headings fold case on both sides (mawk tolower is ASCII-only)" {
    local lib="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/issue_spec_complete.sh"
    run bash -c "source '$lib'; spec_section_filled \"\$(printf '## AÇÃO\n\ntexto\n')\" 'Ação'"
    [ "$status" -eq 0 ]
}

@test "spec_incomplete_reasons: a heading-less template does not waive What / Why" {
    local lib="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/issue_spec_complete.sh" t
    t="$(mktemp)"
    printf 'Free-form report, write anything.\n' >"$t"
    run bash -c "source '$lib'; spec_incomplete_reasons \"\$(printf 'just prose\n\n\`\`\`surface\na.sh\n\`\`\`\n')\" '$t'"
    rm -f "$t"
    [[ "$output" == *"What / Why"* ]]
}

@test "spec_incomplete_reasons: the surface heading is required, prose mentioning it is not enough" {
    local lib="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/issue_spec_complete.sh" t
    t="$(mktemp)"
    printf '## What / Why\n\n## File surface\n\n```surface\n```\n' >"$t"
    run bash -c "source '$lib'; spec_incomplete_reasons \"\$(printf '## What / Why\n\nx; see the File surface below\n\n\`\`\`surface\na.sh\n\`\`\`\n')\" '$t'"
    rm -f "$t"
    [[ "$output" == *"File surface"* ]]
}

@test "CRLF bodies: headings, fences and the surface block still match" {
    local lib="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/issue_spec_complete.sh"
    run bash -c "source '$lib'; spec_incomplete_reasons \"\$(printf '## What / Why\r\n\r\nx\r\n\r\n\`\`\`surface\r\na.sh\r\n\`\`\`\r\n')\""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run bash -c "source '$lib'; section_has_checklist \"\$(printf '## Definition of Done\r\n- [ ] a\r\n')\" 'Definition of Done'"
    [ "$status" -eq 0 ]
}

@test "section filled: a subheading alone is not text; prose between two inline comments is" {
    local lib="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/issue_spec_complete.sh"
    run bash -c "source '$lib'; spec_section_filled \"\$(printf '## Scope\n### Part\n## Next\n')\" Scope"
    [ "$status" -ne 0 ]
    run bash -c "source '$lib'; spec_section_filled \"\$(printf '## Scope\n<!-- a --> real prose <!-- b -->\n')\" Scope"
    [ "$status" -eq 0 ]
    run bash -c "source '$lib'; spec_section_filled \"\$(printf '## Scope\n<!-- a --> <!-- b -->\n')\" Scope"
    [ "$status" -ne 0 ]
}

@test "spec_incomplete_reasons: only the section holding the surface fence is exempt, not any 'surface' name" {
    local lib="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/issue_spec_complete.sh" t
    t="$(mktemp)"
    printf '## Attack surface\n\n## File surface\n\n```surface\n```\n' >"$t"
    run bash -c "source '$lib'; spec_incomplete_reasons \"\$(printf '## Attack surface\n\n## File surface\n\n\`\`\`surface\na.sh\n\`\`\`\n')\" '$t'"
    rm -f "$t"
    [[ "$output" == *"empty Attack surface"* ]]
    [[ "$output" != *"empty File surface"* ]]
}

@test "a missing issue_spec_complete.sh does not block a repo that ships no issue template" {
    local copy repo
    copy="$(mktemp -d)"
    repo="$(mktemp -d)"
    cp -r "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/." "$copy/"
    rm "$copy/lib/issue_spec_complete.sh"
    git -C "$repo" init -q
    run bash -c "cd '$repo' && payload 'gh issue create --title x --body \"$NO_DOD_BODY\"' | '$copy/issue_template_guard.sh'"
    rm -rf "$copy" "$repo"
    [ "$status" -eq 0 ]
}

@test "a missing issue_spec_complete.sh blocks an issue write instead of approving it" {
    local copy
    copy="$(mktemp -d)"
    cp -r "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/." "$copy/"
    rm "$copy/lib/issue_spec_complete.sh"
    run bash -c "payload 'gh issue create --title x --body \"$NO_DOD_BODY\"' | '$copy/issue_template_guard.sh'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"issue_spec_complete.sh is missing"* ]]
    run bash -c "payload 'ls -la' | '$copy/issue_template_guard.sh'"
    [ "$status" -eq 0 ]
    rm -rf "$copy"
}

@test "spec_incomplete_reasons: a complete spec prints nothing; empty section and no surface say why" {
    local lib="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/issue_spec_complete.sh"
    run bash -c "source '$lib'; spec_incomplete_reasons \"\$(printf '## What / Why\n\nx\n\n\`\`\`surface\na.sh\n\`\`\`\n')\""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run bash -c "source '$lib'; spec_incomplete_reasons \"\$(printf '## What / Why\n\n<!-- todo -->\n')\""
    [[ "$output" == *"empty What / Why"* ]]
    [[ "$output" == *"no surface block"* ]]
}
