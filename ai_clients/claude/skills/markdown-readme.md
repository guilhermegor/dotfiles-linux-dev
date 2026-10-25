---
name: s:markdown-readme
description: Use when generating, creating, or writing a README.md file for a project from scratch or from a template, or when checking an existing README against the BlueprintX layout.
effort: medium
argument-hint: [project-name] [github-username]
---

> **Priority:** this project's `CLAUDE.md` and `rules/*.md` take precedence over the guidance below whenever they conflict — treat this skill as a fallback, not a mandate.

There is one README spec, and it lives in `guilhermegor/blueprintx`, not here.
This skill only says where to read it and what to ask before filling it in.
Do not restate the spec in a README or in this file: copy the template, never
this summary.

## Source of truth

Read these from blueprintx `main` before writing (REST works without a clone):

| What | Path in `guilhermegor/blueprintx` |
|---|---|
| Template to fill in | `templates/common/README.template.md` |
| The gate (copy shipped into generated projects as `bin/check_readme_structure.sh`) | `templates/common/bin/check_readme_structure.sh` |
| The gate's CI wrapper | `bin/ci/check_readme_structure.sh` |
| The contract, in prose | `docs/readme-layout.md` |

```bash
set -o pipefail
gh api "repos/guilhermegor/blueprintx/contents/templates/common/README.template.md?ref=main" \
  --jq .content | base64 -d
```

The slug order is whatever the gate enforces today. If this file and the gate
disagree, the gate wins; read it instead of trusting a list copied here. A
generated project already carries the gate at `bin/check_readme_structure.sh`:
run `bash bin/check_readme_structure.sh README.md` and fix what it reports.

## Required inputs

Before writing anything, ask for any of the following not already in `$ARGUMENTS`:

1. **Project name** — exact repository/project name.
2. **GitHub username** — the owner or organisation for badge and link URLs.
3. **Brief description** — 2–4 sentences on what the project does and for whom.
4. **Per author: name, GitHub username and LinkedIn URL** — the Authors section
   needs both a `github.com/<user>` and a `linkedin.com/in/<handle>` link per
   author. The template fills the GitHub link from item 2, which is right only
   when the author is the repo owner; ask for any other author's own username.
5. **Archetype** — one of the values `--list-archetypes` prints on the gate.
6. **Ships to PyPI?** — decides image URLs (below).

Do not infer any of these. Wait for explicit values before generating output.

## Rules that bite (all checked by the gate or its template)

- The first line is `<!-- readme-archetype: NAME -->`, and each section sits
  under a `<!-- slug: NAME -->` marker. Sections are matched by slug, never by
  heading text.
- No emoji, `<img>`, `![...]` or `<picture>` in any heading, H1 to H6, in the
  README or in an example you write.
- The logo goes on its own line below the H1, never inside it:
  `<p align="center"><img src="assets/logo.png" width="200" alt="NAME logo"></p>`
- A disclaimer goes in a footer at the bottom of the README, not in the intro.
- No unrendered `${VAR}` and no `your-linkedin-handle` placeholder in a
  finished README.
- Use absolute image URLs (`https://raw.githubusercontent.com/<user>/<repo>/<branch>/assets/logo.png`)
  whenever the README ships to PyPI: the package page cannot resolve a
  relative path, so `assets/logo.png` renders as a broken image there.

## Guidelines

1. **Keep it concise** — scannable in under 2 minutes.
2. **Show real commands** and their expected output.
3. **Link to details** in `docs/` rather than inlining long explanations.
4. **Keep it updated** — installation steps match the project as it is now.
