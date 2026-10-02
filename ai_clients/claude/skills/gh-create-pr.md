---
name: s:gh-create-pr
description: Use when creating a pull request — analyses branch changes vs main, proposes a title and structured PR body for user approval, then opens the PR via gh CLI.
effort: high
argument-hint: [base-branch — default: main]
allowed-tools: Bash(git log*), Bash(git diff*), Bash(git status*), Bash(git rev-parse*), Bash(git branch*), Bash(git merge-base*), Bash(gh pr*)
---

> **Priority:** this project's `CLAUDE.md` and `rules/*.md` take precedence over the guidance below whenever they conflict — treat this skill as a fallback, not a mandate.

Open a pull request for the current branch. Follow these steps exactly.

## 0. Confirmation gate

Before doing anything else, ask:

> "Open a pull request for the current branch? (yes/no)"

If the user answers **no**, stop immediately.

## 1. Detect context

Run in parallel:

- `git rev-parse --show-toplevel` — absolute repo root; keep it as `$REPO_ROOT` and prefix every
  command below with `cd "$REPO_ROOT" &&` — the harness resets cwd between Bash calls and can
  reset it to a different repo entirely, so an unqualified command answers about whatever the
  shell happens to point at (dotfiles-dev#229)
- `git branch --show-current` — active branch name
- `git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null` — upstream (may fail)
- `gh pr list --head "$(git branch --show-current)" --json number,title,url --limit 1`

Determine the base branch:

1. Use `$ARGUMENTS` if non-empty.
2. Otherwise try `main`, then `master`.

If a PR already exists for this branch, report it:

> "A PR already exists for this branch: #<number> — <title>  
> <url>  
> Proceed anyway? (yes/no)"

If the user answers no, stop.

## 2. Gather changes

Compute the merge base and collect data in parallel. Compare against `origin/<base-branch>`,
never the bare local branch name — a stale local tracking ref silently mis-scopes the diff the
same way an implicit `HEAD` does (dotfiles-dev#229):

```bash
cd "$REPO_ROOT" && git fetch origin "<base-branch>" --quiet
cd "$REPO_ROOT" && git merge-base "origin/<base-branch>" HEAD   # → <merge-base>

cd "$REPO_ROOT" && git log <merge-base>..HEAD --oneline --no-decorate --reverse
cd "$REPO_ROOT" && git diff <merge-base>..HEAD --stat
cd "$REPO_ROOT" && git diff <merge-base>..HEAD -- '*.py' '*.sh' '*.md' '*.json' '*.toml' '*.yaml' '*.yml'
cd "$REPO_ROOT" && git status --short
```

Use the full diff only to understand intent — not to reproduce it in the PR body.

## 3. Compose PR title and body

Derive a concise title (≤ 72 characters) from the commit messages and changed
files. Use Conventional Commit style: `type(scope): imperative summary`.

Then compose the body using this exact template, filling every section from the
gathered diff. Omit subsections that genuinely do not apply, but keep the
section headers. Replace every `[placeholder]` with real content.

````markdown
## Description
**What**: <brief summary of what changed>
**Why**: <motivation — business reason, bug trigger, or requirement>
**How**: <implementation approach — key design decision or pattern used>

---

## Changes Made
**Added**:
- <new feature or file: brief description>
- <dependency: Package@version> (if any)

**Updated**:
- <refactored component> — <reason>

**Fixed**:
- Issue #<number>: <brief description> (omit if none)

---

## Testing
### Manual Testing
- **Test Case 1**:
    - Steps: `<numbered steps>`
    - Expected: <expected outcome>
    - Evidence: <screenshot link or "N/A">

### Automated Testing
- **Unit Tests**:
    - File: `<test file>`
    - Coverage: <percentage> (via `pytest --cov`)
- **Integration Tests**:
    - File: `<tests file>`
    - Status: `OK/NOK`

**Not Applicable**:
- <explain if no testing applies, e.g. "Documentation-only change">

---

## Documentation
- **Code**: Updated docstrings in <files> (or "N/A")
- **Guides**: <section added to README, or "N/A">
- **Changelog**: Entry under <version> (or "N/A")

---

## Additional Notes
**Dependencies**:
- Blocks/Depends on #<PR number> (omit if none)

**Follow-up**:
- Tech debt: <brief note> (omit if none)

**Reviewer Focus**:
- Pay attention to <specific files or logic>
````

## 4. Present for approval

Show the proposed title and body to the user:

> "**Proposed PR**  
> **Title:** `<title>`  
>
> <body>
>
> Approve, or describe what to change:"

Wait for the user's response:

- **Approved / yes / LGTM** → proceed to step 4a.
- **Suggestions** → apply them and re-present from step 4.
- **No / cancel** → stop.

Accept as many revision rounds as the user needs.

## 4a. Draft and reviewers

Ask both questions together in a single prompt:

> "Two quick questions before opening:  
> 1. Open as a **draft** PR? (yes/no)  
> 2. Assign reviewers? Enter GitHub usernames separated by commas, or press  
>    Enter to skip."

Parse the response:

- **Draft**: set `draft=true` if the user answers yes; otherwise `draft=false`.
- **Reviewers**: split the comma-separated list into individual handles,
  stripping whitespace. If the user left it empty, set `reviewers=()`.

## 5. Open the PR

Build the `gh pr create` command from the approved values:

```bash
gh pr create \
  --base <base-branch> \
  --title "<approved title>" \
  --body "$(cat <<'EOF'
<approved body>
EOF
)" \
  [--draft]                          # include only when draft=true
  [--reviewer <handle1,handle2,...>] # include only when reviewers is non-empty
```

### 5a. Verify the issue link

A `Closes #N` line in the body is not a link until GitHub says so: in
renutri, PRs #26 and #28 both carried it, targeted `main`, and returned
`closingIssuesReferences: []` — #25 stayed open and its card never reached
Done, with no error. Right after creating the PR, read back what GitHub
parsed:

```bash
gh pr view <n> --json closingIssuesReferences --jq '.closingIssuesReferences | length'
```

If the body carries a closing keyword (`Closes`/`Fixes`/`Resolves #N`) and
the count is `0`, **warn the user now**, naming the PR and the issue —
not after the merge. Do not edit the body on your own; the fix (re-link
from the PR sidebar, or rely on the repo's branch-name `close-linked-issues`
workflow) is the user's call.

If `gh pr create` itself fails on a GraphQL rate limit, the REST form
(`gh api -X POST repos/<o>/<r>/pulls`) works but **bypasses
`pr_template_guard.sh`**, which matches only `gh pr create|edit` — a
deliberate scope (its body parsing reads `--body`/`--body-file`, not REST
`-f body=`). Fill every `.github/PULL_REQUEST_TEMPLATE.md` section by hand
before using it.

Report the result:

> "PR opened: <url>  
> Draft: <yes/no>  
> Reviewers: <handles or 'none'>"

## Do Not

- Do not open the PR without explicit user approval of title and body.
- Do not skip the confirmation gate (step 0) even when invoked from an agent.
- Do not skip step 4a — always ask about draft and reviewers before opening.
- Do not truncate or omit template sections without noting it to the user.
- Do not push commits — only create the PR against already-pushed commits.
