#!/usr/bin/env bats
#
# sweep_issue_hygiene in subagent_stop_sweep.sh (dotfiles-linux-dev#714): the report-only backstop for
# issue_template_guard.sh - lists open issues with no ```surface block or no milestone, whatever
# route created them. Unreadable -> UNKNOWN, never "all clean".

setup() {
    SWEEP_SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/subagent_stop_sweep.sh"
    REPO="$(mktemp -d)"
    BIN="$REPO/bin"
    mkdir -p "$BIN" "$REPO/lib"
    export PATH="$BIN:$PATH"
    head -n -1 "$SWEEP_SRC" > "$REPO/sweep_funcs.sh"
    local f
    for f in review_thread_gate free_surface kanban_reconcile kanban_reconcile_done dispatch_claims gh_budget roadmap_unblock; do
        cp "$(dirname "$SWEEP_SRC")/lib/$f.sh" "$REPO/lib/"
    done
    source "$REPO/sweep_funcs.sh"
}

teardown() {
    rm -rf "$REPO"
}

# stub_issues JSON -> gh serving the REST list (PRs carry a pull_request key)
stub_issues() {
    cat >"$BIN/gh" <<STUB
#!/bin/bash
[ "\${GH_FAIL:-0}" = 1 ] && exit 1
cat <<'JSON' | jq -r "\${@: -1}"
$1
JSON
STUB
    chmod +x "$BIN/gh"
}

@test "lists issues missing a surface block or a milestone, skips PRs" {
    stub_issues '[
      {"number":1,"body":"```surface\na.sh\n```","milestone":{"number":3}},
      {"number":2,"body":"no block","milestone":{"number":3}},
      {"number":3,"body":"```surface\na.sh\n```","milestone":null},
      {"number":4,"body":"x","milestone":null,"pull_request":{}}
    ]'
    run sweep_issue_hygiene o/r
    [ "$status" -eq 0 ]
    [[ "$output" == *"#2: no "*"surface"* ]]
    [[ "$output" == *"#3: no milestone"* ]]
    [[ "$output" != *"#1:"* ]]
    [[ "$output" != *"#4:"* ]]
}

@test "all clean says so" {
    stub_issues '[{"number":1,"body":"```surface\na.sh\n```","milestone":{"number":3}}]'
    run sweep_issue_hygiene o/r
    [[ "$output" == *"every open issue has"* ]]
}

@test "an unreadable list is UNKNOWN, never all clean" {
    stub_issues '[]'
    GH_FAIL=1 run sweep_issue_hygiene o/r
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
}
