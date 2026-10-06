# Publishing these docs

The site is built with MkDocs Material and versioned with
[mike](https://github.com/jimporter/mike). Most pages are single-sourced from
tracked files (`README.md`, area `CLAUDE.md`, `espanso/**/README.md`) through
`pymdownx.snippets` includes, so edit the source file, never a copy.

## Local preview

```bash
make docs_serve   # poetry install --with docs + live-reload on :8000
make docs_build   # strict build, same check CI runs
```

## First-deploy order

GitHub Pages must serve the `gh-pages` branch, and that branch only exists
after the first deploy. Do it in this order:

1. Merge the docs workflow to `master`.
2. The `docs` workflow's deploy job runs `mike deploy` and creates `gh-pages`
   (version `dev`, alias `latest`, set as the default).
3. Run `make enable_pages` once (needs repo-admin `gh auth`). Until `gh-pages`
   exists it only prints a message and changes nothing; it is idempotent.

## Versions

Every push to `master` deploys `dev` with the `latest` alias. The repo has no
release tags yet; once they exist, a tag job can deploy `X.Y` with
`--update-aliases X.Y latest`.
