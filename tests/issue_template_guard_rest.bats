#!/usr/bin/env bats
#
# issue_template_guard.sh must also judge the REST twin of `gh issue create|edit`:
# `gh api repos/O/R/issues[/N] -X POST|PATCH` (dotfiles-linux-dev#714). Before this, an issue created or
# edited through REST never passed the guard (the orchestrator did exactly that while GraphQL was
# rate-limited). Same hook, same real-argv tokenizer (gh_cmd_match.py `api-issue`), same
# throwaway-repo-with-a-template strategy as tests/issue_template_guard.bats.
#
# Run locally:  bats tests/issue_template_guard_rest.bats

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/issue_template_guard.sh"
    REPO="$(mktemp -d)"
    cd "$REPO"
    git init -q .
    mkdir -p .github/ISSUE_TEMPLATE
    cat > .github/ISSUE_TEMPLATE/seed.md <<'TEMPLATE'
---
name: Seed
about: One repo.
---

**Python · PyPI · public repo**

What this repository is.

### Definition of done
- [ ] Scaffolded
TEMPLATE
    export -f payload
}

teardown() {
    rm -rf "$REPO"
}

payload() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

COMPLIANT_BODY='**Python · PyPI · public repo**\n\nWhat it is.\n\n### Definition of done\n- [ ] a'
BAD_BODY='**Python · PyPI · public repo**\n\nNo definition of done here.'

@test "REST create (-X POST -f body=) with a bad body is blocked" {
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues -X POST -f title=x -f body=\"$BAD_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Definition of done"* ]]
}

@test "REST create with a compliant body passes" {
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues -X POST -f title=x -f body=\"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST create with --method POST and NO body is blocked (REST has no editor mode)" {
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues --method POST -f title=x' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST create is implied by any -f field with no explicit method" {
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues -f title=x -f body=\"$BAD_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST PATCH with a bad body is blocked" {
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues/5 -X PATCH -f body=\"$BAD_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST PATCH that sets no body (state only) is ignored" {
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues/5 -X PATCH -f state=closed' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST PATCH with -F body=@file reads the file and blocks a bad one" {
    printf '%s' 'no structure' > "$REPO/body.md"
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues/5 -X PATCH -F body=@$REPO/body.md' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST create with --input reads the JSON .body member (bad blocks, good passes)" {
    jq -nc '{title:"x", body:"just text"}' > "$REPO/p.json"
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues --input $REPO/p.json' | '$GUARD'"
    [ "$status" -eq 2 ]
    jq -nc --arg b "$(printf '**Python · PyPI · public repo**\n\nx\n\n### Definition of done\n- [ ] a')" \
        '{title:"x", body:$b}' > "$REPO/p.json"
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues --input $REPO/p.json' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST create chained after && is still caught (real argv, not a raw regex)" {
    run bash -c "payload 'true && gh api repos/{owner}/{repo}/issues -X POST -f title=x -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST attached short method (-XPOST) is recognised" {
    run bash -c "payload 'gh api -XPOST repos/{owner}/{repo}/issues -f title=x -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST reads and other endpoints are ignored" {
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues' | '$GUARD'"
    [ "$status" -eq 0 ]
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues/5/comments -f body=hi' | '$GUARD'"
    [ "$status" -eq 0 ]
    run bash -c "payload 'gh api repos/{owner}/{repo}/pulls -X POST -f body=hi' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST text inside a quoted argument is not a command" {
    run bash -c "payload 'echo \"gh api repos/{owner}/{repo}/issues -X POST\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST create naming an explicit owner/repo with no local checkout is blocked as unresolved" {
    run env HOME="$REPO/nohome" bash -c "payload 'gh api repos/some/other-repo/issues -X POST -f title=x -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not resolve the issue template"* ]]
}

@test "REST create in a repo with no template is untouched" {
    rm -rf .github/ISSUE_TEMPLATE
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues -X POST -f title=x -f body=nope' | '$GUARD'"
    [ "$status" -eq 0 ]
}
