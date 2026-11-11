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

@test "REST: a variable only in the owner/repo segment is judged by its literal resource (#822)" {
    run bash -c "payload 'R=o/r; gh api -X PUT repos/\$R/pulls/816/merge -f merge_method=squash -f sha=abc --jq .merged' | '$GUARD'"
    [ "$status" -eq 0 ]
    run bash -c "payload 'gh api repos/\$R/pulls -X POST -f title=x -f body=hi' | '$GUARD'"
    [ "$status" -eq 0 ]
    run bash -c "payload 'gh api -X PUT repos/o/\$N/pulls/816/merge -f sha=abc' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST: a variable repo path to issues, or a variable resource, still fails closed (#822)" {
    run bash -c "payload 'gh api repos/\$R/issues -X POST -f title=x -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api repos/\$R/issues/5 -X PATCH -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api repos/\$O/\$N/issues -X POST -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api repos/o/r/\$X -X POST -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST: a PR-merge loop with a command-substitution read is not an issue write (#870)" {
    run bash -c "payload 'for n in 27 29; do sha=\$(gh api repos/o/r/pulls/\$n --jq .head.sha); gh api -X PUT repos/o/r/pulls/\$n/merge -f merge_method=squash -f sha=\$sha; done' | '$GUARD'"
    [ "$status" -eq 0 ]
    run bash -c "payload 'for n in 27 29; do gh api -X PUT repos/o/r/pulls/\$n/merge -f merge_method=squash; done' | '$GUARD'"
    [ "$status" -eq 0 ]
    run bash -c "payload 'gh api -X PUT repos/o/r/pulls/\$n/merge -f sha=\$sha' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "shell keywords and group openers do not hide an issue write (#870)" {
    run bash -c "payload 'if gh issue create --title x --body nope; then echo ok; fi' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'while true; do gh api repos/o/r/issues -X POST -f body=nope; done' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload '{ gh issue create --title x --body nope; }' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload '! gh issue create --title x --body nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'until false; do gh issue create --title x --body nope; done' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'if true; then :; elif gh issue create --title x --body nope; then :; fi' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'if bash -c \"gh issue create --title x --body nope\"; then :; fi' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'if true; then :; fi' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST: a real issues write inside the same loop shape stays blocked (#870)" {
    run bash -c "payload 'for n in 27 29; do sha=\$(gh api repos/o/r/pulls/\$n --jq .head.sha); gh api repos/o/r/issues -X POST -f title=x -f body=nope; done' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'for n in 27 29; do gh api repos/o/r/issues -X POST -f title=x -f body=nope; done' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'for n in 27 29; do gh api repos/o/r/issues/\$n -X PATCH -f body=nope; done' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'if true; then gh api repos/o/r/issues -X POST -f body=nope; fi' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST: a leading slash is judged like the relative path; a tail that completes an issue path fails closed (#822)" {
    run bash -c "payload 'gh api -X PUT /repos/\$R/pulls/816/merge -f sha=abc' | '$GUARD'"
    [ "$status" -eq 0 ]
    run bash -c "payload 'gh api -X PATCH repos/\$R/comments/5 -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api -X POST repos/\$R/5/labels -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
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

# --- spelling parity: every way of writing the same call reaches the same verdict ------------

@test "REST spellings all blocked: --method=POST, lowercase, -X=POST, URL, trailing slash, query" {
    local spelling
    for spelling in \
        'gh api repos/{owner}/{repo}/issues --method=POST -f body=nope' \
        'gh api repos/{owner}/{repo}/issues -X post -f body=nope' \
        'gh api repos/{owner}/{repo}/issues -X=POST -f body=nope' \
        'gh api https://api.github.com/repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'gh api repos/{owner}/{repo}/issues/ -X POST -f body=nope' \
        'gh api "repos/{owner}/{repo}/issues?x=1" -X POST -f body=nope' \
        'gh api -X POST -f body=nope -- repos/{owner}/{repo}/issues' \
        '/usr/bin/gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'env GH_TOKEN=x gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'GH_TOKEN=x gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'rtk gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'x=$(gh api repos/{owner}/{repo}/issues -X POST -f body=nope)' \
        'gh api repos/{owner}/{repo}/issues \
          -X POST -f body=nope'; do
        run bash -c "payload '$spelling' | '$GUARD'"
        [ "$status" -eq 2 ] || { echo "NOT BLOCKED: $spelling"; return 1; }
    done
}

@test "REST: the LAST body= wins, so a compliant first body cannot mask a bad last one" {
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues -f body=\"$COMPLIANT_BODY\" -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST: an endpoint or method built by the shell is judged as a write, not skipped" {
    run bash -c "payload 'gh api \"repos/\$R/issues\" -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues -X \"\$M\" -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST: text that looks like an issues write but cannot be tokenized fails CLOSED" {
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues -X POST -f body=\"unterminated' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be parsed"* ]]
}

@test "gh issue create via an absolute gh path or env is still judged" {
    run bash -c "payload '/usr/bin/gh issue create --title x --body nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'env X=1 gh issue create --title x --body nope' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "adversarial spellings are all judged (REST and gh issue)" {
    local s
    for s in \
        'gh api -X post repos/{owner}/{repo}/issues -f body=nope' \
        'gh api --method=PATCH repos/{owner}/{repo}/issues/3 -f body=nope' \
        'gh api -XPOST repos/{owner}/{repo}/issues -f body=nope' \
        'gh api /repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'gh -R o/r api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'bash -c "gh api repos/{owner}/{repo}/issues -X POST -f body=nope"' \
        'command gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        '\gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'rtk proxy gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'true; gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'false || gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'echo hi | gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'sleep 1 & gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'gh api repos/{owner}/{repo}/issues -X POST --field body=nope' \
        'bash -c "gh issue create --title x --body nope"' \
        'command gh issue create --title x --body nope' \
        '\gh issue create --title x --body nope' \
        'rtk proxy gh issue create --title x --body nope' \
        'gh -R o/r issue create --title x --body nope'; do
        run bash -c "payload '$s' | '$GUARD'"
        [ "$status" -eq 2 ] || { echo "NOT BLOCKED: $s"; return 1; }
    done
}

# --- PR #730 review findings ---------------------------------------------------------------

@test "nested bash -c parse error does not hide a later outer gh issue create" {
    run bash -c "payload 'bash -c \"'\"'\"; gh issue create --title x --body nope' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "a printed example after a wrapper is not an issue write" {
    run bash -c "payload 'env echo gh issue create --body nope' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "a state-only REST edit does not hide a later gh issue create" {
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues/5 -X PATCH -f state=closed; gh issue create --title x --body nope' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "an unknown (shell variable) method on a numbered endpoint is judged as a possible edit" {
    run bash -c "payload 'M=PATCH; gh api repos/{owner}/{repo}/issues/5 -X \"\$M\" -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "JSON --input labels count: if-label requirement is enforced" {
    cat >> .github/ISSUE_TEMPLATE/seed.md <<'EOF'
<!-- issue-template-guard: require "**Blocked by:**" if-label state:blocked -->
EOF
    jq -nc --arg b "$(printf '**Python · PyPI · public repo**\n\nx\n\n### Definition of done\n- [ ] a')" \
        '{title:"x", body:$b, labels:["state:blocked"]}' > "$REPO/p.json"
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues --input $REPO/p.json' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Blocked by"* ]]
}

@test "printed gh api text is not a write; env/absolute/bash -c gh api writes still are" {
    local s
    for s in \
        'env echo gh api repos/o/r/issues -f title=x' \
        'echo gh api repos/o/r/issues/5 -X PATCH -f state=closed'; do
        run bash -c "payload '$s' | '$GUARD'"
        [ "$status" -eq 0 ] || { echo "WRONGLY BLOCKED: $s"; return 1; }
    done
    for s in \
        'env gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        '/usr/bin/gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        "bash -c 'gh api repos/{owner}/{repo}/issues -X POST -f body=nope'"; do
        run bash -c "payload \"\$1\" | '$GUARD'" _ "$s"
        [ "$status" -eq 2 ] || { echo "NOT BLOCKED: $s"; return 1; }
    done
}

@test "wrapper options that take a value do not hide the real gh call" {
    local s
    for s in \
        'timeout -s KILL 5 gh issue create -t a -b b' \
        'stdbuf -o L gh issue create -t a -b b' \
        'nice -n 5 gh issue create -t a -b b' \
        'ionice -c 3 gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'timeout --signal=KILL 5 gh issue create -t a -b b' \
        'env -u FOO gh issue create -t a -b b' \
        'sudo -u root gh issue create -t a -b b' \
        "env -S 'gh issue create -t a -b b'" \
        "env --split-string='gh api repos/{owner}/{repo}/issues -X POST -f body=nope'" \
        'xargs -n 1 gh issue create -t a -b b'; do
        run bash -c "payload \"\$1\" | '$GUARD'" _ "$s"
        [ "$status" -eq 2 ] || { echo "NOT BLOCKED: $s"; return 1; }
    done
    for s in \
        'env echo gh api repos/o/r/issues -f title=x' \
        "env -S 'echo gh issue create --body nope'" \
        'timeout -s KILL 5 echo gh issue create --body nope'; do
        run bash -c "payload \"\$1\" | '$GUARD'" _ "$s"
        [ "$status" -eq 0 ] || { echo "WRONGLY BLOCKED: $s"; return 1; }
    done
}

@test "understood non-writes pass: plain GET (literal or dynamic), literal sub-resources" {
    local s
    for s in \
        'gh api "repos/$R/issues"' \
        'gh api -X GET "repos/$R/issues"' \
        'gh api repos/{owner}/{repo}/issues/5/comments -f body=x' \
        'gh api repos/{owner}/{repo}/issues/5/labels -f labels[]=a' \
        'gh api repos/{owner}/{repo}/pulls -X POST -f body=x' \
        'gh api user/repos -f name=x' \
        'gh api "$EP"'; do
        run bash -c "payload '$s' | '$GUARD'"
        [ "$status" -eq 0 ] || { echo "WRONGLY BLOCKED: $s"; return 1; }
    done
}

@test "FAIL CLOSED: anything mentioning issues that is not understood as a non-write is judged" {
    local s
    for s in \
        'gh api "repos/$R/issues/5/comments" -f body=x' \
        'gh api repos/{owner}/{repo}//issues -f body=x' \
        'xargs -n1 gh api repos/{owner}/{repo}/issues -f body=nope' \
        'gh api "$EP" -f body=x' \
        'gh api "repos/$R/issues" -X POST' \
        'gh api `echo x` --input f' \
        'gh api "$(echo repos/x)" --field body=x' \
        'gh api "$EP" -X PATCH' \
        'sudo -n gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'timeout 5 gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'nice gh api repos/{owner}/{repo}/issues -X POST -f body=nope' \
        'gh api repos/{owner}/{repo}/issues --method "$M" --input "$F"'; do
        run bash -c "payload '$s' | '$GUARD'"
        [ "$status" -eq 2 ] || { echo "NOT BLOCKED: $s"; return 1; }
    done
}

# --- no control regression: everything the PRE-#730 guard blocked is still blocked ------------

@test "REGRESSION: every gh issue create/edit shape the old guard blocked is still blocked" {
    local s
    for s in \
        'gh issue create --title x --body nope' \
        'rtk gh issue create --title x --body nope' \
        'gh issue create --title x -b nope' \
        'gh issue create --title x -bnope' \
        'gh issue create --title x --body=nope' \
        'gh issue edit 5 --body nope' \
        'gh issue edit 5 -b=nope' \
        'true && gh issue create --title x --body nope' \
        'true; gh issue create --title x --body nope' \
        'false || gh issue create --title x --body nope' \
        'echo a | gh issue create --title x --body nope' \
        'sleep 1 & gh issue create --title x --body nope' \
        'gh issue create --repo o/r --title x --body nope'; do
        run bash -c "payload '$s' | '$GUARD'"
        [ "$status" -eq 2 ] || { echo "REGRESSION, NOT BLOCKED: $s"; return 1; }
    done
    printf '%s' 'nope' > "$REPO/b.md"
    run bash -c "payload 'gh issue create --title x --body-file $REPO/b.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh issue create --title x --body-file /no/such/file' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REGRESSION: the old guard's allowed cases are still allowed" {
    local s
    for s in \
        'gh issue edit 5 --add-label x' \
        'gh issue list' \
        'gh pr create --body nope' \
        'echo "gh issue create --body nope"' \
        'git commit -m "gh api repos/o/r/issues -X POST"'; do
        run bash -c "payload '$s' | '$GUARD'"
        [ "$status" -eq 0 ] || { echo "WRONGLY BLOCKED: $s"; return 1; }
    done
}

@test "REST create in a repo with no template is untouched" {
    rm -rf .github/ISSUE_TEMPLATE
    run bash -c "payload 'gh api repos/{owner}/{repo}/issues -X POST -f title=x -f body=nope' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST: PR review-comment writes are not issue writes, whatever the body says (#874)" {
    run bash -c "payload 'gh api repos/o/r/pulls/52/comments/123/replies -f body=\"see the open writer issues\"' | '$GUARD'"
    [ "$status" -eq 0 ]
    run bash -c "payload 'gh api repos/o/r/pulls/52/comments -f body=\"issues\" -f path=a -f commit_id=b' | '$GUARD'"
    [ "$status" -eq 0 ]
    run bash -c "payload 'gh api -X PATCH repos/o/r/pulls/comments/123 -f body=\"fixes issues\"' | '$GUARD'"
    [ "$status" -eq 0 ]
    run bash -c "payload 'gh api repos/o/r/pulls/52/reviews -f body=issues -f event=COMMENT' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST: an --input file mentioning issues does not make a PR reply an issue write (#874)" {
    echo '{"body": "see the issues"}' > "$REPO/issues-reply.json"
    run bash -c "payload 'gh api repos/o/r/pulls/52/comments/123/replies --input $REPO/issues-reply.json' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST: a repo whose name contains 'issues' still lets PR replies through (#874)" {
    run bash -c "payload 'gh api repos/o/my-issues/pulls/52/comments/123/replies -f body=x' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST: issue writes stay blocked with value flags before the endpoint (#874)" {
    run bash -c "payload 'gh api -X POST repos/o/r/issues -f title=x' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api --hostname h.example.com repos/o/r/issues -X POST' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api --method=POST repos/o/r/issues' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api -XPOST -H \"Accept: x\" -- repos/o/r/issues' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST: every value flag before the endpoint still leaves the issue write blocked (#874)" {
    for flags in "--cache 1h" "-p x" "--preview x" "-q .id" "--jq .id" "-t y" "--template y" "-H Accept:x" "-q .id --cache 1h -t y"; do
        run bash -c "payload 'gh api $flags repos/o/r/issues -X POST -f title=x' | '$GUARD'"
        [ "$status" -eq 2 ]
    done
}

@test "REST: an unrecognised flag before the endpoint fails closed (#874)" {
    run bash -c "payload 'gh api --foo v repos/o/r/issues -X POST -f title=x' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api -X POST -- v repos/o/r/issues -f title=x' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api --foo v repos/o/r/pulls/52/comments/1/replies -f body=issues' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST: shell-built endpoints carrying issues inside a segment stay blocked (#874)" {
    run bash -c "payload 'gh api repos/o/r/issues\$N -X POST -f title=x' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api \"repos/o/r/\$(echo issues)\" -X POST -f title=x' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST: a query string or fragment on the issues endpoint does not hide the write (#874)" {
    run bash -c "payload 'gh api repos/o/r/issues?a=b -X POST -f title=x' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api repos/o/r/issues#frag -X POST -f title=x' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST: graphql queries mentioning issues are not issue writes (#874)" {
    run bash -c "payload 'gh api graphql -f query=\"{ repository { issues { totalCount } } }\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "GraphQL: createIssue mutation with a bad inline body is blocked (#903)" {
    run bash -c "payload 'gh api graphql -f query=\"mutation { createIssue(input:{repositoryId:\\\"R\\\", title:\\\"t\\\", body:\\\"no dod\\\"}) { clientMutationId } }\"' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: createIssue with no body is blocked (#903)" {
    run bash -c "payload 'gh api graphql -f query=\"mutation { createIssue(input:{}) { clientMutationId } }\"' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: createIssue with a compliant body variable is allowed (#903)" {
    # Single-quoted query: double-quoted, the shell expands $body and gh sends another query.
    run guard_cmd "gh api graphql -f query='mutation(\$body:String!){ createIssue(input:{body:\$body}) { clientMutationId } }' -f body=\"$COMPLIANT_BODY\""
    [ "$status" -eq 0 ]
}

@test "GraphQL: updateIssue via --input JSON with a bad body is blocked (#903)" {
    f="$BATS_TEST_TMPDIR/q.json"
    jq -nc '{query: "mutation($b:String!){ updateIssue(input:{id:\"I\", body:$b}) { clientMutationId } }", variables: {b: "no dod"}}' > "$f"
    run bash -c "payload 'gh api graphql --input $f' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST: a shell-built stray positional behind an unknown flag stays blocked (#874)" {
    run bash -c "payload 'gh api --foo v repos/o/r/issues\$N -X POST -f title=x' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api --foo v \"repos/o/r/\$(echo issues)\" -X POST -f title=x' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "REST: a loop of PR review-comment replies is not an issue write (#874, #895)" {
    run bash -c "payload 'for n in 1 2; do gh api repos/o/r/pulls/52/comments/\$n/replies -f body=\"see the writer issues\"; done' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "REST: real issue writes stay blocked after the path-only mention test (#874)" {
    run bash -c "payload 'gh api repos/o/r/issues -X POST -f title=x -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api repos/o/r/issues/5 -X PATCH -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api repos/\$R/issues -X POST -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "coproc and a variable resource segment still block issue writes (#880 review)" {
    run bash -c "payload 'coproc gh issue create --title x --body nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'for n in 1; do gh api -X POST repos/o/r/\$t/\$n -f title=x; done' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'for n in 1; do gh api -X POST repos/o/r/pulls/\$n/../../issues -f title=x; done' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "a dot segment after a literal resource keeps a variable resource fail-closed (#880)" {
    run bash -c "payload 'gh api -X POST repos/o/r/pulls/../\$resource -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api -X POST repos/o/r/pulls/./\$resource -f body=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api -X PUT repos/o/r/pulls/\$n/merge -f sha=abc' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "GraphQL aliased, variable-body and multi-operation mutations are judged (#903)" {
    run bash -c "payload 'gh api graphql -f query=\"mutation{a: createIssue(input:{repositoryId:\\\"x\\\",title:\\\"t\\\",body:\\\"nope\\\"}){issue{id}}}\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"mutation(\$b:String!){createIssue(input:{title:\\\"t\\\",body:\$b}){issue{id}}}\" -F b=nope' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"query{viewer{login}} mutation{createIssue(input:{title:\\\"t\\\"}){issue{id}}}\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"query{viewer{login}}\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "GraphQL mutation hidden in a -F query=@file, -f 'input[body]=' or stdin is still judged (#906 review)" {
    printf '%s' 'mutation{createIssue(input:{title:"t",body:"nope"}){issue{id}}}' > "$REPO/q.graphql"
    run bash -c "payload 'gh api graphql -F query=@$REPO/q.graphql' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"mutation(\$i:CreateIssueInput!){createIssue(input:\$i){issue{id}}}\" -f \"i[body]=nope\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'echo {} | gh api graphql --input -' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL endpoint spellings, input variable names and decoy bodies cannot dodge the guard (#906 review)" {
    run bash -c "payload 'gh api /graphql -f query=\"mutation{createIssue(input:{title:\\\"t\\\",body:\\\"nope\\\"}){a}}\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api GraphQL -f query=\"mutation{createIssue(input:{title:\\\"t\\\",body:\\\"nope\\\"}){a}}\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"mutation(\$x:CreateIssueInput!){createIssue(input:\$x){a}}\" -f \"x[body]=nope\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"mutation(\$x:CreateIssueInput!){createIssue(input:\$x){a}}\" -F x=@-' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"mutation{createIssue(input:{title:\\\"body: x\\\",body:\\\"nope\\\"}){a} createIssue(input:{body:\\\"nope2\\\"}){a}}\"' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL block-string body is parsed whole and a literal beats a compliant -f body (#906 review)" {
    M="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/gh_cmd_match.py"
    cmd='gh api graphql -f query='"'"'mutation{createIssue(input:{body: """hello"""}){a}}'"'"
    run bash -c "printf '%s' \"\$1\" | python3 '$M' api-issue" _ "$cmd"
    [[ "$output" == *'"body": "hello"'* ]]
    run bash -c "payload 'gh api graphql -f query=\"mutation(\$body:String!){c: addComment(input:{body:\$body}){a} i: createIssue(input:{title:\\\"t\\\",body:\\\"nope\\\"}){a}}\" -f body=compliant' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL commas, comments and a stray -f body= cannot hide a bad body (#906 ladder)" {
    run bash -c "payload 'gh api graphql -f query=\"mutation{createIssue,(input:{body:\\\"nope\\\"}){a}}\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"mutation{createIssue(input:{body,:\\\"nope\\\"}){a}}\" -f body=compliant' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"mutation(\$b:String){createIssue(input:{body:\$b})}\" -f body=compliant' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL updateIssue cannot dodge via '$ b', a variable default or a BOM; closing stays allowed (#906 ladder)" {
    # Single-quoted queries: a double-quoted `$b` is the shell's, which blocks for another reason.
    run guard_cmd "gh api graphql -f query='mutation{updateIssue(input:{id:\"I\",body: \$ b}){a}}' -f b=nope"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api graphql -f query='mutation(\$b:String=\"nope\"){updateIssue(input:{id:\"I\",body:\$b}){a}}'"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api graphql -f query='mutation{updateIssue(input:{id:\"I\",body"$'\xef\xbb\xbf'":\"nope\"}){a}}'"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api graphql -f query='mutation(\$i:UpdateIssueInput!){updateIssue(input:\$i){a}}' -f 'i[id]=I' -f 'i[state]=CLOSED'"
    [ "$status" -eq 0 ]
}

@test "GraphQL --input: variables.input.body never shadows a real \$body (#906 ladder)" {
    printf '%s' '{"query":"mutation($body:String){createIssue(input:{title:\"t\",body:$body}){a}}","variables":{"body":"nope","input":{"body":"ok"}}}' > "$REPO/in.json"
    run bash -c "payload 'gh api graphql --input $REPO/in.json' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a compliant body on a sibling field AFTER the mutation is not judged (#906 ladder)" {
    f="$BATS_TEST_TMPDIR/sib.json"
    jq -nc --arg b "$COMPLIANT_BODY" '{query: ("mutation($i:CreateIssueInput!){createIssue(input:$i){a} x: addComment(input:{subjectId:\"S\",body:" + ($b|tojson) + "}){a}}"), variables: {i: {body: "nope"}}}' > "$f"
    run bash -c "payload 'gh api graphql --input $f' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL --input: a -f field is query-string, never a variable (#906 ladder)" {
    f="$BATS_TEST_TMPDIR/qs.json"
    jq -nc '{query: "mutation($b:String){createIssue(input:{title:\"t\",body:$b})}"}' > "$f"
    run bash -c "payload 'gh api graphql --input $f -f b=\"$COMPLIANT_BODY\"' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a binary -F @file is judged blind, not a crash (#906 ladder)" {
    printf '\xff\xfe\x00' > "$BATS_TEST_TMPDIR/bin.dat"
    run bash -c "payload 'gh api graphql -f query=\"mutation{createIssue(input:{title:\\\"t\\\"})}\" -F x=@$BATS_TEST_TMPDIR/bin.dat' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL --input: a bad variables.input.body is blocked, a compliant one allowed (#906 CodeRabbit)" {
    f="$BATS_TEST_TMPDIR/vi.json"
    jq -nc '{query: "mutation($input:UpdateIssueInput!){updateIssue(input:$input){a}}", variables: {input: {id: "I", body: "no dod"}}}' > "$f"
    run bash -c "payload 'gh api graphql --input $f' | '$GUARD'"
    [ "$status" -eq 2 ]
    jq -nc --arg b "$(printf %b "$COMPLIANT_BODY")" '{query: "mutation($input:UpdateIssueInput!){updateIssue(input:$input){a}}", variables: {input: {id: "I", body: $b}}}' > "$f"
    run bash -c "payload 'gh api graphql --input $f' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "GraphQL shell-built queries, string decoys, devices and body-less --input are judged (#906 ladder)" {
    run bash -c "payload 'gh api graphql -f query=\"\$Q\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"\$(cat q.graphql)\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -F query=@/dev/stdin' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"mutation(\$b:String){createIssue(input:{repositoryId:\\\"R\\\",title:\\\"body: \$b\\\"}){a}}\" -f b=compliant' | '$GUARD'"
    [ "$status" -eq 2 ]
    printf '%s' '{"query":"mutation($i:UpdateIssueInput!){updateIssue(input:$i){issue{id}}}","variables":{"i":{"id":"I","state":"CLOSED"}}}' > "$REPO/close.json"
    run bash -c "payload 'gh api graphql --input $REPO/close.json' | '$GUARD'"
    [ "$status" -eq 0 ]
    run bash -c "payload 'gh api graphql -f query=\"mutation{addComment(input:{body:\\\"call createIssue(x)\\\"}){a}}\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "GraphQL mid-query shell variable, rewritten absolute file and oversize file are blind (#906 ladder 2)" {
    run bash -c "payload 'gh api graphql -f query=\"mutation{\$M}\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    printf '%s' '{viewer{login}}' > "$REPO/benign.graphql"
    run bash -c "payload 'printf x > $REPO/benign.graphql && gh api graphql -F query=@$REPO/benign.graphql' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -F query=@$REPO/benign.graphql > $REPO/out.json' | '$GUARD'"
    [ "$status" -eq 0 ]
    { printf '#%.0s' $(seq 1 1100000); printf '\nmutation{createIssue(input:{body:"nope"}){a}}'; } > "$REPO/big.graphql"
    run bash -c "payload 'gh api graphql -F query=@$REPO/big.graphql' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a carriage return ends a comment, so the mutation after it is judged (#906 CodeRabbit)" {
    printf '# c\rmutation{createIssue(input:{body:"nope"}){a}}' > "$REPO/cr.graphql"
    run bash -c "payload 'gh api graphql -F query=@$REPO/cr.graphql' | '$GUARD'"
    [ "$status" -eq 2 ]
    jq -n --rawfile q "$REPO/cr.graphql" '{query:$q}' > "$REPO/cr.json"
    run bash -c "payload 'gh api graphql --input $REPO/cr.json' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a shell expansion inside an inline comment is blind (#906 CodeRabbit)" {
    run bash -c "payload 'gh api graphql -f query=\"mutation{ # \$M\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"mutation{ # \$(cat m)\"' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: file-sourced query text is never judged as shell-expanded (#906 CodeRabbit)" {
    local q='mutation{createIssue(input:{repositoryId:"R",title:"t",body:"'"$COMPLIANT_BODY"' `x` costs $5 ${y} $(z)"}){issue{id}}} # $note'
    printf '%s' "$q" > "$REPO/ok.graphql"
    run bash -c "payload 'gh api graphql -F query=@$REPO/ok.graphql' | '$GUARD'"
    [ "$status" -eq 0 ]
    jq -n --arg q "$q" '{query:$q}' > "$REPO/ok.json"
    run bash -c "payload 'gh api graphql --input $REPO/ok.json' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "GraphQL: shell text only declares a variable in the operation header (#906 security review)" {
    run bash -c "payload 'gh api graphql -f query=\"mutation{\$M:x}\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"mutation{\$@}\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload 'gh api graphql -f query=\"mutation{\$*}\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    run bash -c "payload \"gh api graphql -f query='query(\\\$o:String!){repository(owner:\\\$o,name:\\\"r\\\"){id}}' -f o=x\" | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "GraphQL: a header inside a comment or string declares nothing (#906 security review)" {
    local cmd='gh api graphql -f query="# query($M:x) $M"'
    run bash -c "payload '$cmd' | '$GUARD'"
    [ "$status" -eq 2 ]
    cmd='gh api graphql -f query="{a(b:\"query($M:x)\") $M}"'
    run bash -c "payload '$cmd' | '$GUARD'"
    [ "$status" -eq 2 ]
}

# --- #906 ladder review on 59529e04: quoting decides what the shell builds (#908) ------------------

guard_cmd() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}' | "$GUARD"
}

@test "GraphQL: shell-built positionals and field keys are blind (#906 ladder 6)" {
    run guard_cmd 'gh api graphql $ARGS'
    [ "$status" -eq 2 ]
    run guard_cmd 'gh api graphql "$@"'
    [ "$status" -eq 2 ]
    run guard_cmd 'gh api graphql -f "$Q"'
    [ "$status" -eq 2 ]
    run guard_cmd 'gh api graphql -f "qu${x}ery=mutation{createIssue(input:{body:\"x\"}){a}}"'
    [ "$status" -eq 2 ]
    run guard_cmd "gh api graphql -f query='{viewer{login}}' -F n=\$N"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a double-quoted \$var is shell-built wherever it sits (#906 ladder 6, #908)" {
    run guard_cmd 'gh api graphql -f query="mutation($M:x){a}"'
    [ "$status" -eq 2 ]
    run guard_cmd 'gh api graphql -f query="mutation{query: addStar($M:x)}"'
    [ "$status" -eq 2 ]
    run guard_cmd "gh api graphql -f query='query(\$o:String!){repository(owner:\$o,name:\"r\"){id}}' -f o=\"\$OWNER\""
    [ "$status" -eq 0 ]
}

@test "GraphQL: single-quoted \$ and backticks are text, so reads and inline bodies pass (#906 ladder 6)" {
    run guard_cmd "gh api graphql -f query='{search(query:\"cost \$5\",type:ISSUE,first:1){issueCount}}'"
    [ "$status" -eq 0 ]
    local body
    body="$(printf %b "$COMPLIANT_BODY") \`code\`"
    run guard_cmd "gh api graphql -f query='mutation{createIssue(input:{repositoryId:\"R\",title:\"t\",body:\"\"\"$body\"\"\"}){issue{id}}}'"
    [ "$status" -eq 0 ]
}

@test "GraphQL: an escaped triple quote ends a block string where GraphQL ends it (#906 ladder 6)" {
    printf '%s' 'mutation{a: addStar(input:{starrableId:"""x\\"""  """}){clientMutationId} b: createIssue(input:{repositoryId:"R",title:"t",body:"nope"}){issue{id}}} # """' > "$REPO/bs.graphql"
    run guard_cmd "gh api graphql -F query=@$REPO/bs.graphql"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a deeply nested --input file is blind, not a crash (#906 ladder 6)" {
    { printf '{"query":"mutation{createIssue(input:{body:\\"nope\\"}){a}}","x":'; printf '[%.0s' $(seq 1 100000); printf ']%.0s' $(seq 1 100000); printf '}'; } > "$REPO/deep.json"
    run guard_cmd "gh api graphql --input $REPO/deep.json"
    [ "$status" -eq 2 ]
}

@test "GraphQL: any other command naming the query file, or a directory change, makes it blind (#906 ladder 6)" {
    printf '%s' '{viewer{login}}' > "$REPO/q.graphql"
    run guard_cmd "cp evil q.graphql && gh api graphql -F query=@q.graphql"
    [ "$status" -eq 2 ]
    run guard_cmd "printf x > $REPO/q.graphql && gh api graphql -F query=@q.graphql"
    [ "$status" -eq 2 ]
    run guard_cmd "printf x >|q.graphql && gh api graphql -F query=@q.graphql"
    [ "$status" -eq 2 ]
    run guard_cmd "popd && gh api graphql -F query=@q.graphql"
    [ "$status" -eq 2 ]
    run guard_cmd "builtin cd /tmp && gh api graphql -F query=@q.graphql"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api graphql -F query=@q.graphql"
    [ "$status" -eq 0 ]
}

@test "/graphql sends fields ungrouped: variables[...] are the real variables (#906 ladder 6)" {
    # gh groups fields into `variables` only for the literal `graphql` endpoint.
    run guard_cmd "gh api /graphql -f query='mutation(\$i:UpdateIssueInput!){updateIssue(input:\$i){a}}' -f 'i[id]=I' -f 'variables[i][id]=I' -f 'variables[i][body]=nope'"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api https://api.github.com/graphql -f query='mutation(\$b:String!){createIssue(input:{title:\"t\",body:\$b}){a}}' -f \"b=$COMPLIANT_BODY\" -f 'variables[b]=nope'"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api /graphql -f query='mutation(\$b:String!){createIssue(input:{title:\"t\",body:\$b}){a}}' -f \"variables[b]=$COMPLIANT_BODY\""
    [ "$status" -eq 0 ]
}

@test "GraphQL: an escaped \$ in a double-quoted query is the \$ bash sends (#906 ladder 7)" {
    run guard_cmd "gh api graphql -f query=\"mutation(\\\$i:UpdateIssueInput!){updateIssue(input:\\\$i){a}}\" -f 'i[id]=I' -f 'i[body]=nope'"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api graphql -f query=\"mutation(\\\$i:UpdateIssueInput!){updateIssue(input:\\\$i){a}}\" -f 'i[id]=I'"
    [ "$status" -eq 0 ]
}

@test "GraphQL: an escaped \$ in a nested eval/bash -c is an expansion of the inner shell (#906 ladder 7)" {
    run guard_cmd 'eval "gh api graphql -f query=\"\$Q\""'
    [ "$status" -eq 2 ]
    run guard_cmd 'bash -c "gh api graphql -f query=\"\$Q\""'
    [ "$status" -eq 2 ]
    run guard_cmd 'bash -c "gh api graphql -f query={viewer{login}}"'
    [ "$status" -eq 0 ]
}

@test "GraphQL: a quoted expansion in the field that supplies the body is blind (#906 ladder 7)" {
    Q='mutation($b:String!){createIssue(input:{title:"t",body:$b}){a}}'
    run guard_cmd "gh api graphql -f query='$Q' -f b=\"\${X:-$COMPLIANT_BODY}\""
    [ "$status" -eq 2 ]
    run guard_cmd "gh api graphql -f query='$Q' -f b=\"\${UNSET:+$COMPLIANT_BODY}\""
    [ "$status" -eq 2 ]
    # an expansion in a field that is not the body stays a plain value
    run guard_cmd "gh api graphql -f query='mutation(\$b:String!,\$r:ID!){createIssue(input:{repositoryId:\$r,title:\"t\",body:\$b}){a}}' -f r=\"\$RID\" -f b=\"$COMPLIANT_BODY\""
    [ "$status" -eq 0 ]
}

@test "GraphQL: writers that name a parent directory or nothing make a file read blind (#906 ladder 7)" {
    printf '%s' '{viewer{login}}' > "$REPO/q.graphql"
    run guard_cmd "cp /tmp/evil . && gh api graphql -F query=@$REPO/q.graphql"
    [ "$status" -eq 2 ]
    run guard_cmd "cp /tmp/evil . && gh api graphql -F query=@q.graphql"
    [ "$status" -eq 2 ]
    run guard_cmd "mv /tmp/evil $REPO && gh api graphql -F query=@q.graphql"
    [ "$status" -eq 2 ]
    run guard_cmd "tar -xf /tmp/e.tar && gh api graphql -F query=@$REPO/q.graphql"
    [ "$status" -eq 2 ]
    run guard_cmd "make && gh api graphql -F query=@$REPO/q.graphql"
    [ "$status" -eq 2 ]
    run guard_cmd "export A=1; gh api graphql -F query=@q.graphql | jq ."
    [ "$status" -eq 0 ]
}

@test "GraphQL: relative paths resolve against the payload cwd, not the hook cwd (#906 ladder 7)" {
    printf '%s' 'mutation{createIssue(input:{body:"nope"}){a}}' > "$REPO/q.graphql"
    cd /
    run bash -c "jq -nc --arg c 'gh api graphql -F query=@q.graphql' --arg d '$REPO' '{tool_name:\"Bash\",cwd:\$d,tool_input:{command:\$c}}' | '$GUARD'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: percent-encoded and dot-segment endpoints are still graphql (#906 ladder 7)" {
    for ep in 'gr%61phql' 'x/../graphql' './graphql'; do
        run guard_cmd "gh api $ep -f query='mutation{createIssue(input:{title:\"t\",body:\"nope\"}){a}}'"
        [ "$status" -eq 2 ]
    done
}

@test "a NUL in a word does not crash the matcher (#906 ladder 7)" {
    M="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/gh_cmd_match.py"
    run bash -c "printf 'gh api graphql -f query=x \\0 -F a=@q' | python3 '$M' api-issue"
    [ "$status" -eq 0 ]
}

@test "GraphQL: words the parser cannot place are blind (#906 ladder 8)" {
    local q="query='mutation{createIssue(input:{title:\"t\",body:\"nope\"}){a}}'"
    for cmd in "gh api graphql -if $q" \
        'gh api graphql {-F,query=@evil.graphql}' \
        'gh api graphql -F{a=1,query=@evil.graphql}' \
        "gh api graphql -f query='{viewer{login}}' \"--\$X\"" \
        "gh api 'graphql?query=mutation{a}'"; do
        run guard_cmd "$cmd"
        [ "$status" -eq 2 ]
    done
}

@test "GraphQL: a command substitution beside a file read is blind (#906 ladder 8)" {
    echo '{viewer{login}}' > q.graphql
    run guard_cmd "gh api graphql -F query=@q.graphql -f x=\"\$(cp evil q.graphql)\""
    [ "$status" -eq 2 ]
}

@test "GraphQL: a second write in the chain cannot hide behind the first (#906 ladder 8)" {
    local good="-f query='mutation{updateIssue(input:{id:\"i\",title:\"t\"}){a}}'"
    local bad="-f query='mutation{createIssue(input:{title:\"t\",body:\"nope\"}){a}}'"
    run guard_cmd "gh api graphql $good && gh api graphql $bad"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a file gh downloaded is not trusted (#906 ladder 8)" {
    echo '{viewer{login}}' > q.graphql
    run guard_cmd "gh release download -p q.graphql -O q.graphql && gh api graphql -F query=@q.graphql"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a REST issue write before a GraphQL write is blind (#906 ladder 9)" {
    run guard_cmd "gh api -X PATCH repos/o/r/issues/1 -f title=x && gh api graphql -f query='mutation{createIssue(input:{repositoryId:\"R\",title:\"t\",body:\"nope\"}){a}}'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a quoted '>' value does not hide an expansion (#906 ladder 9)" {
    run guard_cmd "X='-Fquery=mutation{createIssue(input:{body:\"nope\"}){a}}'; gh api graphql -t '>' \"\$X\""
    [ "$status" -eq 2 ]
}

@test "GraphQL: a gh pr checkout may rewrite the file read (#906 ladder 9)" {
    echo '{viewer{login}}' > q.graphql
    run guard_cmd "gh pr checkout 5 && gh api graphql -F query=@q.graphql"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a substitution in an assignment may rewrite the file (#906 ladder 10)" {
    echo '{viewer{login}}' > q.graphql
    run guard_cmd 'X=$(cp /tmp/evil q.graphql); gh api graphql -F query=@q.graphql'
    [ "$status" -eq 2 ]
}

@test "GraphQL: gh issue develop may rewrite the file (#906 ladder 10)" {
    echo '{viewer{login}}' > q.graphql
    run guard_cmd "gh issue develop 5 --checkout && gh api graphql -F query=@q.graphql"
    [ "$status" -eq 2 ]
}

@test "GraphQL: process substitution beside a file read is blind (#906 ladder 10)" {
    echo '{viewer{login}}' > q.graphql
    run guard_cmd 'gh api graphql -f x=<(cp\ /tmp/evil\ q.graphql) -F query=@q.graphql'
    [ "$status" -eq 2 ]
}

@test "REST: two issue writes in one chain are judged blind (#906 ladder 10)" {
    run guard_cmd "gh api -X PATCH repos/o/r/issues/1 -f title=a && gh api -X PATCH repos/o/r/issues/2 -f title=b"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a brace or glob endpoint is blind (#906 ladder 11)" {
    run guard_cmd "gh api {graphql,} -f query='mutation{createIssue(input:{body:\"nope\"}){a}}'"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api gr[a]phql -f query='mutation{createIssue(input:{body:\"nope\"}){a}}'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a shell-built redirect target may rewrite the file (#906 ladder 11)" {
    echo '{viewer{login}}' > q.graphql
    run guard_cmd 'F=q.gr; echo x > "${F}aphql"; gh api graphql -F query=@q.graphql'
    [ "$status" -eq 2 ]
    run guard_cmd 'echo x > q.graph*; gh api graphql -F query=@q.graphql'
    [ "$status" -eq 2 ]
}

@test "GraphQL: a broken nested script is blind beside a matched write (#906 ladder 11)" {
    run guard_cmd "gh api graphql -f query='mutation{updateIssue(input:{id:\"I\",title:\"t\"}){a}}'; bash -c 'gh api graphql -f query=\"mutation{createIssue(input:{body:\\\"nope\\\"}){a}}\" <<EOF'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a quoted > inside bash -c keeps its meaning (#906 ladder 11)" {
    run guard_cmd "bash -c 'gh api graphql -f query=\"{viewer{login}}\" > out.json'"
    [ "$status" -eq 0 ]
}

@test "GraphQL: an unterminated heredoc on gh api fails closed (#906 ladder 11)" {
    run guard_cmd "gh api gr''aphql -F query=@q <<EOF"
    [ "$status" -eq 2 ]
}

@test "GraphQL: variables[query] cannot shadow the judged query (#906 ladder 12)" {
    run guard_cmd "gh api /graphql -f 'query=mutation(\$query:String!){createIssue(input:{title:\"t\",body:\$query}){a}}' -f 'variables[query]=nope'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: brace and escaped > hide no field (#906 ladder 12)" {
    run guard_cmd 'gh api graphql -t {x,-Fquery=@evil.graphql}'
    [ "$status" -eq 2 ]
    run guard_cmd "X='-Fquery=mutation{createIssue(input:{body:\"nope\"}){a}}'; gh api graphql -t \\> \"\$X\""
    [ "$status" -eq 2 ]
}

@test "GraphQL: a redirect before the endpoint does not disguise it (#906 ladder 12)" {
    run guard_cmd "gh api >/dev/null graphql -f query='mutation{createIssue(input:{body:\"nope\"}){a}}'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a too-deep or obfuscated nested gh api is blind (#906 ladder 12)" {
    run guard_cmd 'eval eval eval eval gh api graphql -F query=@evil.graphql'
    [ "$status" -eq 2 ]
    run guard_cmd "bash -c 'gh api gr\"\"aphql -F query=@evil <<EOF'"
    [ "$status" -eq 2 ]
}

@test "REST: a query string on an unrelated endpoint is not a glob (#906 ladder 12)" {
    run guard_cmd "gh api -X DELETE 'repos/o/r/actions/caches?key=x'"
    [ "$status" -eq 0 ]
}

@test "GraphQL: a redirect attached to a word does not disguise it (#906 ladder 13)" {
    run guard_cmd "gh api graphql>/dev/null -f query='mutation{createIssue(input:{body:\"nope\"}){a}}'"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api graphql -t>/dev/null -t -Fquery=@evil.graphql"
    [ "$status" -eq 2 ]
}

@test "GraphQL: an input redirect on an ordinary read stays allowed (#906 ladder 13)" {
    run guard_cmd "gh api graphql -f query='{viewer{login}}' </dev/null"
    [ "$status" -eq 0 ]
}

@test "GraphQL: an empty --flag= value swallows nothing (#906 ladder 13)" {
    run guard_cmd "gh api graphql --template= -Fquery=@evil.graphql"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a brace list with a quoted space is still a split (#906 ladder 13)" {
    run guard_cmd 'gh api graphql -t {x" ",-Fquery=@evil.graphql}'
    [ "$status" -eq 2 ]
}

@test "GraphQL: an obfuscated api word and an uppercase scheme are judged (#906 ladder 13)" {
    run guard_cmd "gh a''pi graphql -F query=@evil <<EOF"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api HTTPS://api.github.com/graphql -f query='mutation{createIssue(input:{body:\"nope\"}){a}}'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: an untokenizable \$'...' query fails closed (#906 ladder 8)" {
    run guard_cmd "gh api graphql -f query=\$'mutation{createIssue(input:{body:\"it\\'s\"}){a}}'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: ordinary reads stay allowed (#906 ladder 8)" {
    local q="query='{viewer{login}}'"
    for cmd in "gh api graphql -f $q -f owner=\"\$OWNER\"" \
        "gh api graphql -f $q -F o=\"\$(whoami)\" --jq .data" \
        "gh api graphql --paginate -f $q -q.data"; do
        run guard_cmd "$cmd"
        [ "$status" -eq 0 ]
    done
}

@test "GraphQL: a read selected by operationName ignores a sibling createIssue (#908)" {
    run guard_cmd "gh api graphql -f query='query R{viewer{login}} mutation M{createIssue(input:{title:\"t\"}){clientMutationId}}' -f operationName=R"
    [ "$status" -eq 0 ]
}

@test "GraphQL: the createIssue operation selected by operationName is still blocked (#908)" {
    run guard_cmd "gh api graphql -f query='query R{viewer{login}} mutation M{createIssue(input:{title:\"t\"}){clientMutationId}}' -f operationName=M"
    [ "$status" -eq 2 ]
}

@test "GraphQL: several operations and no operationName still fail closed (#908)" {
    run guard_cmd "gh api graphql -f query='query R{viewer{login}} mutation M{createIssue(input:{title:\"t\"}){clientMutationId}}'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: createIssue named only in a comment or string is not a write (#908)" {
    run guard_cmd "gh api graphql -f query='query{search(query:\"createIssue(x)\"){issueCount}} # createIssue(y)'"
    [ "$status" -eq 0 ]
}

@test "GraphQL: an unselected mutation's object variable default does not taint the read (#908)" {
    run guard_cmd "gh api graphql -f query='mutation M(\$i: In = {title:\"t\"}){createIssue(input:\$i){clientMutationId}} query R{viewer{login}}' -f operationName=R"
    [ "$status" -eq 0 ]
}

@test "GraphQL: only fragments the selected operation reaches are judged (#908)" {
    local frag='fragment F on Mutation{createIssue(input:{title:\"t\"}){clientMutationId}}'
    run guard_cmd "gh api graphql -f query='query R{viewer{login}} mutation M{...F} $frag' -f operationName=R"
    [ "$status" -eq 0 ]
    run guard_cmd "gh api graphql -f query='query R{...F} $frag' -f operationName=R"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api graphql -f query='query R{...G} fragment G on Mutation{...F} $frag mutation M{viewer{login}}' -f operationName=R"
    [ "$status" -eq 2 ]
}

@test "GraphQL: variables[operationName] is a variable, never the /graphql selector (#908)" {
    local doc="query R{viewer{login}} mutation M{createIssue(input:{title:\\\"t\\\"}){clientMutationId}}"
    run guard_cmd "gh api /graphql -f query='$doc' -f operationName=M -f 'variables[operationName]=R'"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api /graphql -f query='$doc' -f operationName=R -f 'variables[operationName]=M'"
    [ "$status" -eq 0 ]
}

@test "GraphQL --input: operationName selecting a read beside a createIssue is allowed (#908)" {
    local f="$BATS_TEST_TMPDIR/op.json"
    printf '%s' '{"query":"query R{viewer{login}} mutation M{createIssue(input:{title:\"t\"}){clientMutationId}}","operationName":"R"}' > "$f"
    run guard_cmd "gh api graphql --input $f"
    [ "$status" -eq 0 ]
    printf '%s' '{"query":"query R{viewer{login}} mutation M{createIssue(input:{title:\"t\"}){clientMutationId}}","operationName":"M"}' > "$f"
    run guard_cmd "gh api graphql --input $f"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a read-only pullRequest/reviewThreads query with escaped quotes is allowed (#908)" {
    run guard_cmd "gh api graphql -f query=\"{repository(owner:\\\"guilhermegor\\\",name:\\\"dotfiles-linux-dev\\\"){pullRequest(number:953){state headRefOid reviewThreads(first:50){nodes{id isResolved comments(last:1){nodes{databaseId author{login}}}}}}}}\" --jq '.data'"
    [ "$status" -eq 0 ]
}

@test "REST: a one-variable repo before a bodyless issue sub-resource is allowed (#963)" {
    run guard_cmd 'gh api repos/$R/issues/5/dependencies/blocked_by -F issue_id=1'
    [ "$status" -eq 0 ]
    run guard_cmd 'gh api repos/$R/issues/5/sub_issues -F sub_issue_id=1'
    [ "$status" -eq 0 ]
    run guard_cmd 'gh api repos/$OWNER/$REPO/issues/5/sub_issues -F sub_issue_id=1'
    [ "$status" -eq 0 ]
}

@test "REST: a variable repo still blocks issue create and edit (#963)" {
    run guard_cmd 'gh api repos/$R/issues -f title=x'
    [ "$status" -eq 2 ]
    run guard_cmd 'gh api repos/$R/issues/5 -f body=x'
    [ "$status" -eq 2 ]
}

@test "REST: a variable repo before a bodyless sub-resource still blocks a body field (#976 review)" {
    # R='o/r/issues/5?x=' makes the real request PATCH issues/5 with the body.
    run guard_cmd 'gh api "repos/$R/issues/5/sub_issues" -X PATCH -f body=x'
    [ "$status" -eq 2 ]
    run guard_cmd 'gh api repos/$R/issues/5/labels -f title=x'
    [ "$status" -eq 2 ]
    run guard_cmd 'gh api repos/$R/issues/5/sub_issues --input payload.json'
    [ "$status" -eq 2 ]
    run guard_cmd 'gh api repos/$R/issues/5/sub_issues -F "$K=x"'
    [ "$status" -eq 2 ]
}

@test "REST: -f on a pull-request merge endpoint is not an issue write (#908)" {
    run guard_cmd "gh api -X PUT repos/guilhermegor/dotfiles-linux-dev/pulls/967/merge -f merge_method=squash -f sha=abc123"
    [ "$status" -eq 0 ]
}

# --- #910: variable defaults and same-command file writes ------------------------------------------

GOOD_BODY='**Python · PyPI · public repo**\n\nx\n\n### Definition of done\n- [ ] a'

@test "GraphQL: an unsupplied variable is judged by its literal default (#910)" {
    run guard_cmd "gh api graphql -f query='mutation(\$b:String=\"$GOOD_BODY\"){createIssue(input:{repositoryId:\"X\",title:\"t\",body:\$b}){issue{id}}}'"
    [ "$status" -eq 0 ]
    run guard_cmd "gh api graphql -f query='mutation(\$b:String=\"nope\"){createIssue(input:{repositoryId:\"X\",title:\"t\",body:\$b}){issue{id}}}'"
    [ "$status" -eq 2 ]
    # no default or a non-literal default: still fail closed
    run guard_cmd "gh api graphql -f query='mutation(\$b:String){createIssue(input:{repositoryId:\"X\",title:\"t\",body:\$b}){issue{id}}}'"
    [ "$status" -eq 2 ]
    run guard_cmd "gh api graphql -f query='mutation(\$b:String=\$c){createIssue(input:{repositoryId:\"X\",title:\"t\",body:\$b}){issue{id}}}'"
    [ "$status" -eq 2 ]
    # a supplied variable overrides the default
    run guard_cmd "gh api graphql -f b=nope -f query='mutation(\$b:String=\"$GOOD_BODY\"){createIssue(input:{repositoryId:\"X\",title:\"t\",body:\$b}){issue{id}}}'"
    [ "$status" -eq 2 ]
}

@test "GraphQL: a file rewritten or reached after cd in the same command is blind (#910)" {
    mkdir "$REPO/sub"
    jq -nc --arg q "mutation{createIssue(input:{repositoryId:\"X\",title:\"t\",body:\"$GOOD_BODY\"}){issue{id}}}" \
        '{query: $q}' > "$REPO/q910.json"
    cp "$REPO/q910.json" "$REPO/sub/other.json"
    run guard_cmd "gh api graphql --input $REPO/q910.json"
    [ "$status" -eq 0 ]
    # the file exists and is compliant at the hook's cwd, so only the same-command logic can block
    run guard_cmd "printf '{}' > $REPO/q910.json && gh api graphql --input $REPO/q910.json"
    [ "$status" -eq 2 ]
    run guard_cmd "cd sub && gh api graphql --input q910.json"
    [ "$status" -eq 2 ]
    run guard_cmd "cd sub && gh api graphql -F query=@q910.json"
    [ "$status" -eq 2 ]
}

@test "GraphQL: default parsing resists comments, nulls, block strings, earlier operations (#910)" {
    local tail='{createIssue(input:{repositoryId:"X",title:"t",body:$b}){issue{id}}}'
    # a commented `"""` must not blank the real declaration (real default "bad")
    run guard_cmd "gh api graphql -f query='mutation(
# \"\"\"
\$b:String=\"bad\"
# \"\"\" \$b:String=\"$GOOD_BODY\"
)$tail'"
    [ "$status" -eq 2 ]
    # a block-string default and a named operation
    run guard_cmd "gh api graphql -f query='mutation M(\$b:String=\"\"\"$GOOD_BODY\"\"\")$tail'"
    [ "$status" -eq 0 ]
    # a redeclared variable is ambiguous
    run guard_cmd "gh api graphql -f query='mutation(\$b:String=\"$GOOD_BODY\",\$b:String=\"bad\")$tail'"
    [ "$status" -eq 2 ]
    # an earlier operation's declaration is not the mutation's
    run guard_cmd "gh api graphql -f query='query Q(\$b:String=\"$GOOD_BODY\"){viewer{login}} mutation M$tail'"
    [ "$status" -eq 2 ]
    # an explicit null in --input overrides the default
    jq -nc --arg q "mutation(\$b:String=\"$GOOD_BODY\")$tail" '{query: $q, variables: {b: null}}' \
        > "$REPO/null910.json"
    run guard_cmd "gh api graphql --input $REPO/null910.json"
    [ "$status" -eq 2 ]
    jq -nc --arg q "mutation(\$b:String=\"$GOOD_BODY\")$tail" '{query: $q}' > "$REPO/def910.json"
    run guard_cmd "gh api graphql --input $REPO/def910.json"
    [ "$status" -eq 0 ]
}
