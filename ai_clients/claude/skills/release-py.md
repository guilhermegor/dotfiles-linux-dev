---
name: s:release-py
description: Use when the ecosystem arm of a release is PyPI — computing the next version above BOTH the PyPI and Test PyPI floors, and driving the Test PyPI rehearsal → install-verify → PyPI publish two-step. Loaded by s:release after it has decided a release is warranted and what to bump; not invoked directly.
effort: high
argument-hint: [package name, bump type, and last tag — supplied by s:release]
allowed-tools: Bash(curl*), Bash(jq*), Bash(gh workflow*), Bash(gh run*), Bash(pip install*), Read, Grep
---

> **Priority:** this project's `CLAUDE.md` and `rules/*.md` take precedence over the guidance below whenever they conflict — treat this skill as a fallback, not a mandate.

You are the **PyPI arm** of a release. `s:release` has already established that a release is
warranted and which bump applies; you own the two things that are PyPI-specific: **the version
floor** and **the publish/verify mechanics**.

Do not re-decide whether to release — that judgement belongs to `s:release`, and repeating it here
would let the two disagree.

## A. The version floor — BOTH indices, never PyPI alone

The next version must be **greater than the max of what is already published on PyPI AND on Test
PyPI**:

```bash
curl -s https://pypi.org/pypi/<pkg>/json      | jq -r '.info.version'   # 404 if never published
curl -s https://test.pypi.org/pypi/<pkg>/json | jq -r '.info.version'
```

**Why both:** a Test PyPI rehearsal permanently raises that index's floor. If `0.25.0` was pushed
to Test PyPI but never released to PyPI, PyPI sits at `0.24.0` and Test PyPI at `0.25.0` — so the
next "correct" version `0.24.1` passes the PyPI gate and **fails the Test PyPI gate**.

Compute `next = bump(max(pypi_version, testpypi_version))` and hand `next` back to `s:release` for
its proposal step. State out loud that **PyPI will show gaps — that is expected**; version numbers
are free, correctness is not.

⚠️ **A negative index read is "unknown", not "absent".** A 404 or a missing version can be CDN lag,
not proof. Retry before concluding a version is unpublished — `/simple/` and `pip` have both denied
a version the JSON API was already serving.

⚠️ **A red `release-pypi.yaml` run does NOT mean the wheel is unpublished — the index decides.**
The `pypi` publish job can succeed while a later *cosmetic* step (`Create GitHub Release`) fails,
turning the whole run red; reading the red X and re-dispatching is the wrong move. Once the publish
job has succeeded the workflow is **no longer idempotent** — re-dispatching makes twine reject the
duplicate version, so the run goes red *again* and you still have no tag. Instead:

- **Read the index first:** `curl -s https://pypi.org/pypi/<pkg>/json | jq -r '.info.version'`. If
  it already shows `<next>`, the wheel shipped — do not re-run the publish.
- **Re-run only the broken step:** `gh run rerun <id> --failed` (reuses the good `pypi` job).
- **Fallback — tag/release by hand:** `gh release create v<next> --target <sha>`, then confirm
  `gh release view v<next> --json isDraft` shows `isDraft=false`. A missing tag is not cosmetic:
  dynamic versioning and the next release's `git diff v<next>..HEAD` gate both depend on it.

## B. Publish — Test PyPI first, then PyPI, each verified

Only after `s:release` has the user's explicit confirmation. Dispatch it yourself: the two PyPI
release workflows are in `permissions.allow` (`gh workflow run` and the REST `/dispatches` form,
bare and `rtk`-prefixed), so do not hand the command to the operator.

**Fallback — only if the auto-mode classifier still refuses** (`[Create Public Surface]`, measured
on filings-rfb, 2026-10-25): stop, print the exact command for the operator to run by hand, and
wait for their go-ahead before verifying. Never widen the allowlist to get past a refusal.

```bash
gh workflow run release-test-pypi.yaml -f version=<next>
```

Then **verify by install** before promoting — never trust a single index read:

- Poll the run to green: `gh run list --workflow=release-test-pypi.yaml --limit 1`.
- `pip install -i https://test.pypi.org/simple/ <pkg>==<next>` in a throwaway venv, and **retry on
  failure** — both `/simple/` and the file host lag a fresh upload, so first-attempt-fail then
  success is normal. Ground truth is the workflow's publish log showing twine's `200 OK` plus a
  successful install on retry.
- **Verify by observable state, never by tool chatter.** `pip install -q` *suppresses* the
  `Successfully installed` line, so grepping for that text is a false-negative. Confirm the version
  actually imports: `python -c "import <pkg>; print(<pkg>.__version__)"` — that is the proof, not
  pip's stdout.

Only once Test PyPI is install-verified:

```bash
gh workflow run release-pypi.yaml -f version=<next>
```

Verify the same way (green run + `pip install <pkg>==<next>` with retry).

## C. Report back to `s:release`

Hand back, for its report block:

- Test PyPI: published + install-verified (or the failure)
- PyPI: published + install-verified (or the failure)
- Any index-floor gap that was skipped, and why

## The rehearsal only rehearses the SHARED steps

A Test PyPI run validates **only the steps the two workflows have in common**. A step living
**only** in `release-pypi.yaml` debuts in production on every release, having never run.

Diff the two workflows before trusting the rehearsal — **the delta is the hole**. Measured case: an
`upload/download-artifact` bump *was* covered by the Test PyPI run, but a `gh-release@v1→v3` bump
existed only in the prod workflow, ran for the first time ever in the real release, and failed.

Two traps that follow from it:

- **Never `files: dist/*` in a release step** — it globs a tracked 0-byte `dist/.keep` and GitHub
  rejects 0-byte assets. Name `dist/*.whl` + `dist/*.tar.gz`.
- **A failed `action-gh-release` is worse than a red X.** v3 creates a **draft**, uploads, then
  promotes; aborting mid-way leaves the release `draft=true`, and **GitHub creates no tag for a
  draft** — so PyPI ships while tag-derived versioning silently loses its tag.

## Do Not

- Do not compute the next version from PyPI alone — always `max(PyPI, Test PyPI)`.
- Do not declare a release broken on a single negative index read — retry first.
- Do not promote to PyPI before Test PyPI is **install**-verified, not merely green.
- Do not treat a green workflow run as a shipped artifact — check per-job conclusions; a `skipped`
  publish behind a cancelled `fail-fast` matrix reads as success at the run level.
- Do not decide *whether* to release or *what* to bump — that is `s:release`'s call.
