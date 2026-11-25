---
name: s:release-rename
description: Use when a published package is being renamed — the forge repo, the PyPI distribution, the import package, the docs site, boards, local checkout and downstream consumers — and the rename must end in a release without losing release history. Loaded by s:release when the shipped change is a rename; not invoked directly.
effort: high
argument-hint: [old name, new name (shim + old-project delete are the defaults; overrides come from the tracking issue)]
allowed-tools: Bash(rtk git grep*) Bash(rtk git worktree*) Bash(rtk git mv*) Bash(rtk git tag*) Bash(rtk gh workflow*) Bash(rtk gh run*) Bash(rtk gh api*) Bash(rtk gh project*) Bash(rtk curl*) Bash(jq*) Bash(pip install*) Bash(poetry install*) Read Grep Glob
---

> **Priority:** this project's `CLAUDE.md` and `rules/*.md` take precedence over the guidance below whenever they conflict — treat this skill as a fallback, not a mandate.

You are the **rename arm** of a release. A rename is not a standalone flow: it ends in a release,
and `s:release` still owns *whether* to release and *what* to bump (a rename is breaking, so a
major bump — see step 2). You own the **order of operations**, the **local-state hazards** and the
**sweep**, which `s:release-py` does not cover. The publish mechanics themselves stay in
`s:release-py`.

Measured on four renames: `filings-cvm` / `filings-b3` / `filings-rfb` → `opendata-*`
(2026-11-11/12) and `pure-docs-br` → `purepii-br` (purepii-br#63, shipped as purepii-br 2.0.0 on
2026-11-19, shim-less break, 20-version backfill on both indexes), plus one queued (the
`purecalendars` rename, purecalendars#75). Every step below cost real time once.

⚠️ **The forge redirects, so nothing forces the issue.** GitHub redirects the old repo URL and old
clones keep working, so a half-done rename produces no error — it produces drift. Verify each
phase by observable state, never by the absence of a failure.

## 1. Decide first, record on the tracking issue

Before touching anything, write these three decisions on the tracking issue. The first two have
standing defaults the owner set on 2026-11-18. Apply them unless the tracking issue says otherwise
for this rename:

- **Shim for `import <old>`** (default). The new wheel also ships `src/<old>/__init__.py`, which
  re-exports the new package (`from <new> import *`, plus `__all__` and `__version__`) and emits
  one `DeprecationWarning` naming the new import. Add `<old>` to `pyproject.toml` `packages`, and
  add one test that imports `<old>` and asserts the warning. Remove the shim at the next major
  bump, and say so in that release's notes. opendata-* shipped a clean break (cvm#420), which
  predates this default.
- **Delete the old PyPI project** (default), and the old Test PyPI project too. Do this only
  **after** step 4 has install-verified the new name on PyPI. Deleting the project frees the name
  for anyone to register; the owner accepted that risk. PyPI deletion is web-only (project
  Settings → Delete project), so hand the owner the two URLs and wait for confirmation. Never
  report the deletion as done before then.
- **Which runtime markers keep their old name** (state dirs, rc-file markers, cache keys; see
  step 8). This one has no default. If it is unanswered, stop and ask.

## 2. Rename distribution AND import package in one release, major bump

Both names change together, in one release, with a **major** bump (breaking; pre-1.0 follows
`s:release`'s 0.x table).

Measured failure: opendata-* split the two across two days (cvm#418 → #419 → #420) and shipped
`pip install opendata-cvm` with `import filings_cvm` in between. Do the dist name in
`pyproject.toml`, `PACKAGE_NAME` in both release workflows, and the **quoted name the code passes
to `importlib.metadata.version("<dist>")`** in the same change as the `src/<pkg>` move —
otherwise `__version__` and provenance stamps silently fall back to `0.0.0` once installed under
the new name (cvm#419).

## 3. Register the OIDC pending publishers BEFORE the first publish

Register a pending publisher for the new name on **both** PyPI and Test PyPI before dispatching
anything. The claims must match the new repo (lessons `pypi-oidc-publisher-claims-must-match`,
`pypi-oidc-trusted-publishing`): repository, exact workflow filename, environment name, and
*PyPI Project Name* = the new distribution name.

⚠️ **Read the repo's actual workflow filenames and `environment: name:` values first. Do not
assume the current blueprintx convention.** Measured 2026-11-18 (purecalendars#75): the repo was
scaffolded before the template moved to hyphens, so it carries `release_pypi.yaml` / environment
`release_pypi`, while the publishers had been registered as `release-pypi.yaml` / `release-pypi` —
the first publish would have been refused. Either:

- **Preferred:** align the repo to the template during the rename (rename the files, recreate the
  GitHub environments **with their protection rules**), then register the template's names; or
- register the publisher with the repo's real names.

Workflow filename, `environment.name`, GitHub *Settings → Environments* and the publisher's
*Environment name* field must be identical in all four places.

## 4. Backfill every stable tag under the new name

Release history must not be lost: old versions have to exist on the new project. This is the
cvm#419 mechanism — a `backfill=true` input on both release workflows that skips the normal jobs
and rebuilds each `vX.Y.Z` tag with only the distribution name rewritten, uploaded with
`skip-existing` (74 releases for cvm). Each backfilled version keeps its original code and its
original import name.

Before dispatching, confirm both workflows already define the `backfill` input (`rtk git grep -n backfill -- .github/workflows`); if not, land it first (cvm#419), since an undeclared input makes the dispatch fail. Dispatch Test PyPI first, then PyPI (use the repo's real workflow filenames from step 3, not the template's), and install-verify each (`s:release-py` §B):

```bash
cd <absolute-repo-path> && rtk gh workflow run <test-pypi-workflow-file> --ref <default-branch> -f version=<any-dummy> -f backfill=true
```

Keep the old name literal in the backfill job (`old="filings-cvm"` stayed in `release-*.yaml` on
purpose, cvm#420) — historical tags still carry it. Then cut the regular renamed release through
`s:release-py`; that release is where the import name changes for consumers.

## 5. Local state — close sessions and the editor before moving the directory

Run `/session-closeout` in every Claude session on the repo and close the editor **before**
`mv`-ing the local checkout. A session holding the old path keeps writing to it.

## 6. `git worktree repair` BEFORE any `git worktree prune`

Save the path→branch map first: `cd <absolute-repo-path> && rtk git worktree list --porcelain > <scratch-file>` — it is the only
record of which branch each worktree had.

After `mv old new`, each worktree's `.git` file still points at the old path, which git reads as
"deleted". The order is `mv` → `git worktree repair <every-new-worktree-path>` → only then `prune`,
and only for leftovers. Measured 2026-11-11 (lesson `moving-a-repo-repair-worktrees-before-any-prune`):
`prune` first deleted the admin metadata of 126 worktrees on `filings-cvm`; recovery was possible
but the staged-vs-unstaged split was lost.

Also: in-project venvs have absolute shebangs and break the `pre-commit` hook on the first commit
after the move. `cd <absolute-repo-path> && rm -rf .venv && poetry install` as part of the move.

## 7. Rename the Claude project directory to match

Rename `~/.claude/projects/<old-key>` to `<new-key>`, where a key is the absolute checkout path with
every `/` replaced by `-` (e.g. `/home/<user>/github/<old>` becomes `-home-<user>-github-<old>`);
derive both from the real old and new paths, or the project's memory is silently orphaned.

## 8. The sweep — the forge identifier, not the spelling

Grep `owner/repo` **first**, never the bare name (lesson
`a-rename-sweep-must-separate-the-forge-name-from-local-markers`, dotfiles-linux-dev#387:
147 files mentioned the name, 6 carried the breaking form):

```bash
cd <absolute-repo-path> && rtk git grep -l 'owner/<old>'     # must change
cd <absolute-repo-path> && rtk git grep -l '<old>'           # classify every extra hit
```

For each remaining hit ask: **is this string read at runtime?** Examples that are not the repo's
name but share its spelling: `importlib.metadata.version("<dist>")` (breaks at import — step 2),
cache and state directories, env-var prefixes, rc-file begin/end markers. A marker renamed here
leaves a previously-installed machine with an unrecognised block that the next run duplicates.
Also check whether any code **branches** on the name:
`rtk git grep -nE '(=|==|\[\[|case|test).{0,20}<old>' -- '*.sh' 'bin/**' 'Makefile'`.

## 9. Leave the historical record untouched — and say so

Transcripts, backlog entries, changelog history and citations (`filings-cvm#164`) record what
happened under the old name; GitHub redirects the links. Do not rewrite them, and state that
decision in the commit body so the omission reads as a choice (dotfiles-linux-dev#981 did exactly
this).

## 10. Big rename PRs

- **CodeRabbit caps at 100 files** (free plan). cvm#420 had 720 files; CodeRabbit posted "Review
  skipped: Too many files" and even an explicit `@coderabbitai review` was refused. The owner
  merged with the "Review threads answered" gate bypassed and said why in a PR comment. Expect it:
  split mechanical moves from logic where possible, or have that bypass decision ready.
- **Test-deletion gates read a renamed test as deleted** (blueprintx#1073, lesson
  `test-deletion-gates-read-a-rename-as-a-deletion`): a `gate-change-ok: <reason>` line naming the
  rename is the owner lever until that is fixed. `check_gate_integrity.py` accepts it in the **PR
  body or** as a commit trailer; cvm#420 used the PR body (no commit carried it).

## 11. Branch names must not auto-close the tracking issue

The closer reads the **branch name** (`<type>/<N>-…` closes `#N`) as well as `Closes` keywords
(lesson `a-branch-named-after-an-issue-closes-it-even-when-the-pr-only-refs-it`). cvm#418 and
opendata-b3#58 were closed by mistake before the release landed. Name the rename branch for the
rename, not the issue number; close the issue by hand after the install-verify (step 4).

## 12. Downstream

- **Boards:** retitle each kanban board to `<new> kanban`. That is the whole board step: no
  source list names a repo any more. `discover_roadmap_boards`
  (`ai_clients/claude/hooks/lib/kanban_reconcile.sh`, #1022) reads the authenticated user's
  projects at runtime and takes the repo from the board's linked repository, falling back to the
  `<repo> kanban` title only when none is linked. So a repo renamed on the forge is picked up by
  itself (GitHub renames the linked repo with it), and a board left titled `<old> kanban` with no
  linked repo is reported `UNKNOWN`, never swept under the old name (that was the
  `filings-*` breakage, dotfiles-linux-dev#981). Verify by observable state: run the reconcile
  and check the board's line names `<new>`. Only a board that must not be swept needs a manual
  entry: `ROADMAP_BOARDS_EXCLUDE` (project numbers) or a `.github/roadmap-board` file in the repo.
- **blueprintx** template pins, the profile README, greenfield specs
  (`.specs/_ecosystem/package-families.md`) and memory files.
- **Consumers:** notify the sessions and projects that depend on the package, with **exact
  versions** (perfil_mensal_cvm waited on opendata-rfb 2.0.0).

## Report back to `s:release`

- Decisions recorded (shim/break, old PyPI project, kept markers) and where
- Publishers registered per index, with the workflow filenames and environments they match
- Backfill: tags rebuilt, install-verified on Test PyPI and PyPI
- Local state: worktrees repaired (count), project dir renamed
- Sweep: forge-identifier hits changed, runtime markers deliberately kept, history left untouched
- Downstream: boards retitled and seen by the reconcile, consumers notified with versions

## Do Not

- Do not run `git worktree prune` before `git worktree repair`.
- Do not split the distribution rename and the import rename across releases.
- Do not register a publisher from the template's workflow names without reading the repo's own.
- Do not rename a runtime marker, state dir or `importlib.metadata` name as if it were the forge name.
- Do not rewrite historical records to match the new name.
- Do not name the rename branch `<type>/<tracking-issue-N>-…`.
- Do not depart from the step 1 defaults (shim, delete the old project) unless the tracking issue
  records the owner's override for this rename.
- Do not delete the old PyPI project yourself, or before the new name is install-verified.
- Do not decide *whether* to release or *what* to bump — that is `s:release`'s call.
