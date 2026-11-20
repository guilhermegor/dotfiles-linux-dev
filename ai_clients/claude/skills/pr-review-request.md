---
name: s:pr-review-request
description: Use when the operator wants the short team-chat (Slack) message that asks teammates to review a pull request — "write the review request", "draft the Slack message for this PR", "ask for review on these PRs".
effort: low
argument-hint: [optional: nothing — every input is asked]
---

> **Priority:** this project's `CLAUDE.md` and `rules/*.md` take precedence over the guidance below whenever they conflict — treat this skill as a fallback, not a mandate.

You draft ONE short chat message asking for a PR review. You print it; the operator copies it.
You never post it, and you make no `gh` or network calls.

## 1. Ask, in one batch, every run

Ask these together, never infer or look up any of them:

1. Reviewer mention(s), exactly as the operator wants them typed (e.g. `@<reviewer>`).
2. Issue link (optional — omit the line if none).
3. PR link(s). If more than one, also a short scope per PR and whether merge order matters.
4. `[<Area>]` tag.
5. Title language — ask every run, no default, no per-repo setting.
6. Optional extra line: a deploy prerequisite, a merge-order note, or a blocker.

No login-to-mention map, no config file: the operator supplies every handle each time.

## 2. Draft

Single PR:

```text
[<Area>] <short title, in the asked language>
PR: <PR URL>
Issue: <issue URL>
<one extra line, if any>
<reviewer mention(s)>
```

Several PRs of one issue — ONE message, never one per PR; title and issue appear once:

```text
[<Area>] <short title, in the asked language>
PR 1/3 — <scope>: <PR URL>
PR 2/3 — <scope>: <PR URL>
PR 3/3 — <scope>: <PR URL>
Issue: <issue URL>
<merge-order note, only if order matters>
<reviewer mention(s)>
```

## 3. Rules

- Every line except the title is optional; drop a line when it does not apply.
- At most ONE extra line. If the operator gives more, keep the single most blocking item and tell
  them the rest belongs in the PR body.
- Print the draft in a code block and stop. Do not post it, and do not offer to.
- Placeholders only in this skill and its examples: no company, repository, person or channel
  names, no private URLs.
- Standalone: `s:gh-create-pr` does not call or suggest this skill.
