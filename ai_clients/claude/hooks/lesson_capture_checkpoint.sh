#!/bin/bash
# PostToolUse (Bash matcher) hook: at the completion boundary, force the
# lesson-capture question instead of relying on soft prose.
#
# Why this exists: the "capture generalizable scaffold/toolchain lessons before
# moving on" rule lives only as a SessionStart reminder + prose in CLAUDE.md —
# both soft. They raise awareness but never block completion, and demonstrably
# fail: a fix, its PR, and the summary shipped with no lesson logged until the
# user asked manually. A reminder at session *start* is the wrong moment — the
# lesson is only knowable once the work reveals what generalizes. A checkpoint at
# the completion boundary (a PR or issue being opened) converts "Claude might
# remember" into "Claude is always asked."
#
# It fires right after a `gh pr create` / `gh issue create` and injects an
# ADVISORY reminder as additionalContext — it never hard-blocks, so it can never
# wedge an unrelated session. Claude either captures the lesson or explicitly
# declines in one line.
#
# Hook I/O contract (deliberately NOT the usual script convention, matching
# pr_template_guard.sh): this file speaks only through stdout JSON + exit code —
# so there is intentionally no lib/common.sh / print_status here. It also fails
# OPEN everywhere: any uncertainty exits 0 silently, so it can never disrupt an
# unrelated Bash call.

set -u

# Fail open if jq (used to parse the hook payload) is unavailable.
command -v jq >/dev/null 2>&1 || exit 0

emit_reminder() {
    # PostToolUse additionalContext is advisory: Claude reads it, is not blocked.
    local context
    context="$(cat <<'EOF'
[lesson-capture checkpoint] A PR/issue was just opened — the completion boundary.
Before wrapping up, decide explicitly: did this work surface a *generalizable*
scaffold or toolchain lesson (a reusable seam, tooling, convention, guardrail,
command/skill/agent/rule/hook/config/installer change — NOT a project-specific
business rule)?

- If YES: capture it now, before moving on. Route by WHERE THE FIX LANDS:
    * fix edits a scaffolding template (~/github/blueprintx/templates/) →
      BlueprintX store ~/.claude/memory/lessons/
    * fix edits the Claude/dotfiles toolchain (~/github/dotfiles-dev/ai_clients/claude/)
      → Claude-toolchain store ~/.claude/memory/lessons-claude-toolchain/
  Save one file per lesson + update that store's README index. Then regenerate
  this repo's git-ignored mirror(s) under .specs/_lessons/ — run
  `make lessons_mirror` (inside dotfiles-dev) or the deployed generator
  (`bash ~/.claude/hooks/lib/generate_lesson_mirrors.sh`) elsewhere. The mirror
  is GENERATED, never hand-appended (dotfiles-dev#386) — do not hand-edit
  .specs/_lessons/*.md.
- If NO: say so in one line and continue. Do not skip the decision silently.
EOF
)"
    jq -cn --arg ctx "$context" \
        '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
}

main() {
    local payload tool command

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    # Only fire on an actual `gh pr create` / `gh issue create` (optionally
    # rtk-prefixed), anchored to a line start so a mere mention inside a body or
    # commit message does not trip the checkpoint.
    # ponytail: line-anchored, not a full shell parse — good enough; tighten only
    # if a body line literally starting with "gh pr create" ever false-fires.
    printf '%s' "$command" \
        | grep -Eq '^[[:space:]]*(rtk[[:space:]]+)?gh[[:space:]]+(pr|issue)[[:space:]]+create([[:space:]]|$)' \
        || exit 0

    emit_reminder
    exit 0
}

main "$@"
