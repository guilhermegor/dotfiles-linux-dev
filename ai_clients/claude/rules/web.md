---
paths:
  - "**/*.py"
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.js"
  - "**/*.jsx"
  - "**/*.mjs"
  - "**/*.cjs"
  - "**/*.go"
  - "**/*.rs"
---

# Web / HTTP Preferences

> **Priority rule:** These are personal, language-agnostic defaults for code that speaks
> HTTP. Whenever a project-level CLAUDE.md (or any instruction inside the active repository)
> conflicts with anything here, the project context takes precedence. Treat this file as a
> fallback, not a mandate.

> **This is the first *concern*-scoped rule file, and that is deliberate.**
> Every other rule in this directory is *language*-scoped — `python.md` loads for `*.py`,
> `bash.md` for `*.sh`. HTTP is not a language: the same defect appears in FastAPI, NestJS,
> Go and axum alike, so scoping this by language would mean writing it four times and letting
> the four copies drift. `web.md` therefore loads **alongside** `python.md` for a `.py` file,
> and alongside `javascript.md` for a `.ts` file. That layering is additive and intended —
> a file can match several rule files, and each contributes its own concern.
>
> **On the `paths:` list above — it is as narrow as it can honestly be made, and that is
> not very narrow.** It is restricted to the languages in the mapping table below (so it
> never loads for Bash, Java, Ruby, or a `pyproject.toml`), but it is *not* restricted to
> directories where HTTP code tends to live. Patterns like `**/api/**`, `**/routers/**`, or
> `**/handlers/**` were considered and rejected: FastAPI's canonical entrypoint is a
> root-level `main.py`, Go handlers routinely live beside the code they serve, and any
> directory convention is a convention, not a guarantee — a path filter that misses the file
> where the defect lives is worse than no filter, because it fails silently. The cost of the
> broad list is that this file also loads for scripts that never open a socket; the cost is
> bounded (one short file) and is paid in exchange for never missing the code that matters.

## HTTP status codes: by name, never by bare integer

Where the framework — or an already-installed library, or the standard library — exposes a
named HTTP status constant, **use it. A bare numeric status literal is a finding.**

```python
# ❌ the number carries no intent
@app.get("/users/", status_code=200)
def read_users(): ...

# ✅ the constant says what it means
@app.get("/items/", status_code=status.HTTP_200_OK)
def read_items(): ...
```

Two distinct failure modes, not one:

1. **Illegible intent.** `200` and `404` are readable by habit; the rest are memorised
   trivia. At a glance nobody distinguishes `422` (Unprocessable Content) from `412`
   (Precondition Failed), and `409`, `428`, `451` mean nothing without a lookup.
   `HTTP_412_PRECONDITION_FAILED` needs no lookup.
2. **A typo survives.** `status_code=20` is a *valid integer*. It fails at runtime — or
   worse, succeeds with the wrong semantics. `status.HTTP_20_OK` does not resolve, so the
   same typo is caught at import/compile time instead of in production.

The authoritative list of codes and their names is the
[IANA HTTP Status Code Registry](https://www.iana.org/assignments/http-status-codes/http-status-codes.txt).

### Per-stack mapping

| Stack | Preferred | Instead of |
|---|---|---|
| FastAPI / Starlette | `status.HTTP_201_CREATED` | `201` |
| Django REST Framework | `status.HTTP_204_NO_CONTENT` | `204` |
| Flask / Werkzeug | `HTTPStatus.NOT_FOUND` (stdlib `http`) | `404` |
| NestJS | `HttpStatus.FORBIDDEN` | `403` |
| Express / Fastify | `StatusCodes.CONFLICT` (`http-status-codes`) | `409` |
| Go | `http.StatusTeapot` | `418` |
| Rust / axum | `StatusCode::BAD_REQUEST` | `400` |

⚠️ **Python needs no new dependency for the generic case** — `http.HTTPStatus` is standard
library. Prefer the *framework's* constant only where the framework ships one, because that
is what the surrounding code already reads like. Never add a dependency to satisfy this rule
when the stdlib or an installed package already covers it.

### Where this applies, and where it does not

**Apply it** — these are positions with a known, framework-specific meaning:

- `status_code=<int>` / `status=<int>` keyword arguments
- `res.status(<int>)`, `@HttpCode(<int>)`, `HTTPException(status_code=<int>)`
- a `raise` or `return` of a response constructed with a literal status

**Do not apply it** — these need judgment and flagging them mechanically is noise:

- `if resp.status_code == 200:` — a bare comparison with no framework marker
- any integer in the 100–599 range in unrelated arithmetic (ports, counts, sizes, timeouts)

A rule that flagged every integer between 100 and 599 anywhere would be noise, and noise is
how a check gets turned off.

### Already covered for Python — do not re-implement it

`ruff` **PLR2004** (magic-value-comparison) is already active in every BlueprintX-scaffolded
Python project (`"PL"` is in `templates/python-common/ruff.toml` `[lint].select`). It fires on
the *comparison* form:

```python
if resp.status_code == 200:      # PLR2004 fires — already caught, no new check needed
```

It is **silent on the keyword-argument form**:

```python
@app.get("/users/", status_code=200)   # PLR2004 does not fire — this is the real gap
```

So the comparison half is already mechanically enforced for Python. Anything built on top of
this rule should target the keyword-argument half and nothing else; re-covering PLR2004 would
be a second implementation of a check that already runs (dotfiles-linux-dev#333).
