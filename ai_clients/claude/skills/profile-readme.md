---
name: s:profile-readme
description: Use when the GitHub profile README (the `<user>/<user>` repo) must
  be refreshed from the current state of the package ecosystem, in both
  languages — after a round of package decisions, a publish, or a rename.
effort: medium
argument-hint: [profile-repo] [planning-repo]
allowed-tools: Bash(gh api*) Bash(gh issue list*) Bash(gh pr create*) Bash(git fetch*) Bash(git switch*) Bash(git add*) Bash(git commit*) Bash(git push*) Bash(curl*) Bash(python3*) Read Edit Write Grep
---

> **Priority:** this project's `CLAUDE.md` and `rules/*.md` take precedence over the
> guidance below whenever they conflict — treat this skill as a fallback, not a mandate.

**Comment discipline:** read `~/.claude/skills/code-comments/SKILL.md` before writing
any code this skill produces or edits.

## Public-only rule (read first)

This skill lives in a public repo and its output is a public README. Neither may
ever contain:

- names of private repos, private boards or private projects;
- paths under the owner's home directory, or names of employer and client projects;
- anything taken from session memory that is not already public.

The roadmap lists **only** items that exist as issues in the planning repo **and**
that the owner has marked as public. An item you cannot show to be both is left out,
never paraphrased. When unsure, omit it and say so in the PR.

## Inputs

`profile-repo` is the `<user>/<user>` repo; `planning-repo` is the repo holding the
family table and scaffold issues. If either is not given, ask — do not guess.

## Sources (read in this order)

1. **Family table** — the planning repo's `.specs/_ecosystem/package-families.md`:
   the family rows and their boundaries.
2. **Roadmap** — open scaffold issues in the planning repo, grouped by family,
   filtered by the public-only rule above.
3. **PyPI** — a package goes under **Shipped** only if
   `https://pypi.org/pypi/<name>/json` answers HTTP 200. Use an unfiltered client
   (`curl -s -o /dev/null -w '%{http_code}'`, or `rtk proxy curl`): a token-saving
   proxy can hide the status. Check on the day of the run, never from memory.
4. **Renames** — open rename issues: show "being renamed to `<new>`" next to the
   old name until the new one answers 200 on PyPI.

Read issues over REST (`gh api repos/<owner>/<repo>/issues...`) when GraphQL is
rate-limited.

## Steps

1. **Branch from `origin/<default>`**, never a local branch. Resolve the default
   branch from `refs/remotes/origin/HEAD`, then:
   `cd <abs-path> && git fetch origin <default> && git switch -c <branch> origin/<default>`.
2. **Rebuild** the Families, Shipped and Roadmap sections from the sources above.
   Keep the rest of the file exactly as the owner wrote it.
3. **Mirror** the same change into the translated README, then run the repo's
   parity check (`scripts/check_readme_parity.py`) and fix until it passes.
4. **Self-check** before committing:
   - every Shipped package returned 200 from PyPI;
   - no roadmap item is also under Shipped;
   - each family description matches its row in the family table;
   - every rename shows both names;
   - the public-only rule holds for every line you added.
5. **Open the PR** with the repo's PR template. List what moved between sections
   and why. Do not merge.

## Common mistakes

| Mistake | Guard |
|---|---|
| Listing a package as Shipped that is not on PyPI yet | step 3 of Sources, HTTP 200 only |
| A roadmap item that already shipped | self-check, second bullet |
| English and translated file drifting apart | parity check in Steps 3 |
| Family description stale against the family boundary | re-read the family table every run |
| Rename shown under only one name | Sources step 4 |
