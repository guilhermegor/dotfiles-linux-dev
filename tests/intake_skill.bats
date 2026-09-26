#!/usr/bin/env bats
# Structural checks for ai_clients/claude/skills/intake.md — the s:intake
# parent orchestrator (dotfiles-dev#422). It carries no executable logic of
# its own (it sequences four already-shipped child skills via the Skill
# tool), so this suite pins the frontmatter contract and the reuse links
# rather than mocking a runtime.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SKILL="$REPO_ROOT/ai_clients/claude/skills/intake.md"
}

@test "intake.md exists at the expected source path" {
  [ -f "$SKILL" ]
}

@test "frontmatter declares the s: namespace name" {
  grep -qx 'name: s:intake' "$SKILL"
}

@test "description follows the required 'Use when' convention" {
  grep -q '^description: Use when' "$SKILL"
}

@test "frontmatter declares effort and allowed-tools" {
  grep -qE '^effort: ' "$SKILL"
  grep -qE '^allowed-tools: ' "$SKILL"
}

@test "references all four child skills by name" {
  for child in s:intake-discover s:intake-refine s:intake-shipped s:intake-plan; do
    grep -qF "$child" "$SKILL"
  done
}

@test "points to code-comments.md instead of restating the comment rule" {
  grep -qF 'code-comments/SKILL.md' "$SKILL"
}

@test "states it never dispatches" {
  grep -qiF 'never dispatches' "$SKILL"
}
