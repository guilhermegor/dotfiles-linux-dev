#!/usr/bin/env bats
#
# Pins the PR-to-issue link verification guidance (dotfiles-linux-dev#585): a `Closes #N`
# line is not a link until GitHub reports it in closingIssuesReferences.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SKILL="$REPO_ROOT/ai_clients/claude/skills/gh-create-pr.md"
ISSUE_CMD="$REPO_ROOT/ai_clients/claude/commands/issue.md"

@test "gh-create-pr verifies closingIssuesReferences after creating the PR" {
  run grep -F 'gh pr view <n> --json closingIssuesReferences' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "gh-create-pr documents the REST fallback bypassing the template guard" {
  run grep -F 'bypasses' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "c:issue verifies the link and documents the close-linked-issues complement" {
  run grep -F 'gh pr view <n> --json closingIssuesReferences' "$ISSUE_CMD"
  [ "$status" -eq 0 ]
  run grep -F 'close-linked-issues' "$ISSUE_CMD"
  [ "$status" -eq 0 ]
}

@test "c:issue allows the gh pr view call it instructs" {
  run grep -F 'Bash(rtk gh pr view*)' "$ISSUE_CMD"
  [ "$status" -eq 0 ]
}
