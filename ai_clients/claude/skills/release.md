---
name: s:release
description: Use when the user asks to cut a release, bump the version, or publish a package — decides whether a release is warranted and what to bump from the shipped-artifact diff and Conventional Commit types since the last tag, then delegates the publish mechanics to the matching ecosystem arm (s:release-py for PyPI, workflow-dispatch for everything else).
effort: high
argument-hint: [none — reads the repo state]
allowed-tools: Bash(git log*), Bash(git tag*), Bash(git describe*), Bash(git diff*), Bash(git rev-parse*), Bash(rtk git log*), Bash(rtk git diff*), Bash(gh workflow*), Bash(gh run*), Bash(gh release*), Read, Glob, Grep
---

> **Priority:** this project's `CLAUDE.md` and `rules/*.md` take precedence over the guidance below whenever they conflict — treat this skill as a fallback, not a mandate.

You are deciding and cutting a release for this repository. Follow these steps exactly.

The governing rule: **a version is a claim about the shipped artifact — only mint one when the
artifact changed.** A "minor-bump every merge" habit ships byte-identical artifacts under new
numbers, filling the changelog with noise and draining the version of meaning. The release trigger
is a **diff in the shipped artifact**, never "a PR merged".

This skill owns the **decision**; an ecosystem arm owns the **mechanics**. Keep the seam — a
decision step that assumes one packaging ecosystem is how this skill silently misfires on the first
repo of another shape.

## 1. Resolve the shipped paths

The shipped paths are the files that actually end up in the distributed artifact. Read them, in
order:

1. A repo-committed `.claude/release.conf` — one path/glob per line, `#` comments ignored.
2. Otherwise the default for a Python package: `src/` and `pyproject.toml`.

⚠️ **The default is a Python assumption, and on a non-Python repo it fails silently and inverted —
it SUPPRESSES a release instead of erroring.** Before trusting an empty diff, check the shipped
paths against **ground truth: the packaging manifest** — the release workflow, `Formula/*.rb`,
`debian/install`, `MANIFEST.in`, whatever actually copies files into the artifact.

Measured case: blueprintx's product is `bin/` + `templates/`, it had no `release.conf`, and its
docs-only `pyproject.toml` stub satisfied the "publishable repo" gate — so **every** merge of a
whole session reported `NO RELEASE NEEDED` while 44 shipped files had changed. Nothing went red.

**If the repo's shape differs from the default, say so and have the user commit a
`.claude/release.conf`** — the same file the `release_dispatch_guard` and `release_due_nudge` hooks
read, so all three agree. Three diverging lists contradict each other.

**Not shipped by default** (never in a Python wheel): `.github/`, `bin/`, `tests/`, `docs/`,
`SECURITY.md`, `Makefile`, CI config. On a tool whose product *is* `bin/`, that list is wrong —
which is the point of the check above.

## 2. Decide whether to release at all

```bash
git describe --tags --abbrev=0          # → <last-tag>; fails if there are no tags yet
git diff --name-only <last-tag>..HEAD -- <shipped-paths...>
```

- **No tags yet** → first release; propose the project's declared version, or `0.1.0`.
- **Shipped diff empty** → **STOP. No release.** Say plainly: *"No shipped change since
  `<last-tag>` — ci/docs/chore/test do not get a release."* Do not publish, do not tag.
- **Shipped diff non-empty is necessary, not sufficient** — it proves these files were *touched*,
  never that the artifact *changed* (dotfiles-linux-dev#100). A diff touching only a comment, docstring
  prose, or formatting inside a `.py` file is non-empty in bytes and semantically empty. One-line
  discriminator, per changed `.py` file: `ast.dump(ast.parse(old_src)) == ast.dump(ast.parse(new_src))`.
  If every changed file is `.py` and AST-identical → **STOP. No release**, same as an empty diff —
  say *"Shipped diff since `<last-tag>` is comment-only (AST-identical) — no release."* This check
  is Python-only: any non-`.py` shipped file in the diff, or a file the parser cannot read, is
  always a real change and must never be suppressed. The `release_dispatch_guard` and
  `release_due_nudge` hooks apply this same rule — see their `semantic_diff_empty()`.
- **Shipped diff non-empty and not AST-identical** → continue.

**A repeated "nothing to do" earns one ground-truth check, not habituation.** The cost of believing
a wrong suppression is an action that never happens, which leaves no trace.

## 3. Compute the bump from Conventional Commit types

Scan `git log <last-tag>..HEAD` subjects and bodies. Take the **highest** signal present:

| Highest signal since the tag | Pre-1.0 (`0.x`) bump | `>=1.0` bump |
|---|---|---|
| breaking (`type!:` or `BREAKING CHANGE:`) | **MINOR** (0.24.x → 0.25.0) | MAJOR |
| `feat:` | **PATCH** (0.24.0 → 0.24.1) | MINOR |
| `fix:` / hotfix | **PATCH** | PATCH |

**Honour 0.x semantics while `<1.0`** — breaking → MINOR, feat/fix → PATCH. Cut `1.0.0`
deliberately when the API is stable, then switch to full major/minor/patch. Apply the table; do not
leave this to recall.

## 4. Detect the ecosystem, and get the version floor from its arm

**Detect — never assume.** Check the repo for, in order:

| Signal | Arm | Version floor |
|---|---|---|
| `pyproject.toml` + a `release-*pypi.yaml` workflow | **`s:release-py`** | `max(PyPI, Test PyPI)` |
| a `workflow_dispatch` release Action, no PyPI publish | **dispatch arm** (§6b) | the **git tag** |
| `package.json` / `Cargo.toml` / `*.gemspec` | future arm — **stop and ask** | — |

If two signals match (a repo publishing to both PyPI and a package manager), ask which is being
released rather than picking one.

Load the matching arm and ask it for the floor, then `next = bump(floor)`.

## 5. Announce the computed version, then cut

🔴 **CUT IT. Do not ask.** Standing decision, 2026-08-30 (dotfiles-linux-dev#171): *"sempre seguir com
a release quando possível, prefiro que sempre que possível seja publicado mediante o código estar
funcional."*

⚠️ **This step used to end in a question, and the question added no information.** By the time it
runs, step 2 has already found a non-empty shipped diff on the default branch — which means the
change cleared every required check. "Is the code functional" is answered before you get here.
Asking converted *working code, published* into *working code, unpublished, pending an answer
nobody was waiting to give*: six releases in one day, each preceded by a proposal answered "sim".

**Announce, do not ask.** The bump is computed in step 3 from the commit signals, so there is no
judgment left to confirm — but state it, so a wrong bump table becomes visible rather than silent:

> **Cutting `<next>`**
> - Shipped change since `<last-tag>`: `<n>` files (`<list>`)
> - Highest commit signal: `<breaking|feat|fix>` → `<bump>` (pre-1.0 rules)
> - Ecosystem: `<pypi | workflow-dispatch | …>` (detected from `<signal>`)
> - Floor: `<what the arm reported>`

Then go straight to step 6.

### The one thing that still holds a release

**A known defect in the shipped diff** — and only this one, because it is the only input that is
not derivable from the repository. The measured precedent: a vendor-allowlist PR merged at 01:11Z
with an `import(variable)` bypass, and the issue describing that bypass was opened at 01:35Z,
*before* the cut. Shipping it would have put a deny-by-default gate with a documented hole into
every generated project, and **a gate that creates false confidence is worse than none.**

⚠️ **Do not automate this by searching issues for the shipped paths.** Measured: that search
returned **6 matches for a 2-file diff**, none of them a fault in those files — issues mention a
path for context far more often than they report a defect in it. A veto on that signal would
block nearly every release; trusting it would be theatre. Surface the issues as **context, never
a verdict**, and hold only when a defect is known to be *in the shipped code* — which is
something this session knows, not something a query answers.

🎯 The test that separates the two: does the check answer from **data**, or from something **the
session knows**? Breaking-change detection is data. "Did something I already learned make this
artifact wrong" is memory, and no query reaches it.

## 6. Publish via the arm

### 6a. PyPI

Hand off to **`s:release-py`**: Test PyPI → install-verify → PyPI → install-verify.

### 6b. Workflow dispatch (tag-driven, ecosystem-agnostic)

```bash
gh workflow run <release-workflow>.yml -f version=<next>
```

Then verify — **all three, none is implied by another**:

1. **Per-job conclusions**, not the run's overall status:
   `gh run view <id> --json jobs --jq '.jobs[] | "\(.name) \(.conclusion)"'`.
   A `skipped` publish behind a cancelled `fail-fast` matrix reads as success at the run level.
2. **The tag exists**: `git fetch --tags && git tag -l '<next>'`.
3. **The release is not a draft**: `gh release view <next> --json isDraft,assets`.
   A draft has **no tag** — so a half-finished `action-gh-release` ships the package while
   tag-derived versioning silently loses its tag.

## 7. Report

> Released `<pkg>` `<next>` via `<ecosystem>`:
> - Published: `<targets, each with how it was verified>`
> - Tag: `<next>` present, release not a draft
> - Skipped: `<none | what, and why>`

## The four verification rules — they are NOT ecosystem-specific

Carry these into whichever arm runs. Each was learned from a release that looked fine:

1. **A green run ≠ a shipped artifact.** Check per-job conclusions.
2. **Verify the artifact AND the tag.** A draft release creates no tag.
3. **A cached negative is "unknown", not "absent".** Retry before concluding something is
   unpublished — CDN lag denies versions that already exist.
4. **A red run ≠ an unpublished artifact — the mirror image of rule 1.** The package **index**,
   not the Actions run status, is the source of truth for *"did it publish?"*. A run can end red
   because a *cosmetic post-publish step* (e.g. `Create GitHub Release`) failed **after** the
   publish job already succeeded. This is likeliest exactly when the CI provider is degraded —
   which is when the run status is least trustworthy. Read the index (for PyPI:
   `pypi.org/pypi/<pkg>/json`) before concluding nothing shipped; then apply the remediation below.

## When the run is red but the artifact already published

Once the publish job succeeds the workflow is **no longer idempotent**, so the remediation is
asymmetric — do not reach for the obvious "just run it again":

- **Do NOT re-dispatch the whole workflow.** The index rejects the duplicate version → the run
  goes red *again*, and you still have no tag.
- **Re-run only the failed jobs:** `gh run rerun <id> --failed` reuses the good publish job and
  retries just the broken step (e.g. `Create GitHub Release`).
- **Fallback — create the tag/release by hand:** `gh release create <tag> --target <sha>`, then
  confirm `gh release view <tag> --json isDraft` shows `isDraft=false` (a draft creates no tag).
- **A missing tag is not cosmetic:** dynamic versioning and the *next* release's gate
  (`git diff <tag>..HEAD`) both depend on it — a published-but-untagged release mis-scopes the
  following release's diff.

## Do Not

- Do not release for a change that does not alter the shipped artifact (ci/docs/chore/test).
- Do not trust the Python default shipped paths on a non-Python repo — check the packaging manifest.
- Do not assume the ecosystem; detect it, and stop and ask when nothing matches.
- Do not hard-code one ecosystem's mechanics into this skill — that is what the arms are for.
- Do not hold a release for a confirmation — step 5 announces the computed version and cuts.
  The only thing that holds one is a defect KNOWN to be in the shipped diff.
- Do not treat a green run as proof; verify jobs, tag, and draft state.
- Do not keep stacking release dispatches; one version per shipped change.
