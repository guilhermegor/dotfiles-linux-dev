# AGENTS.md

Agent-agnostic global instructions for this machine's operator — read by
every AI coding agent that drives it. Claude Code reaches it through an
import (`@AGENTS.md` in its `CLAUDE.md`); OpenAI Codex CLI and any other
tool with a global instructions file load their own deployed copy of this
same file directly.

Source of truth: `ai_clients/shared/AGENTS.md` in dotfiles-dev. Edit this
source file, never a deployed copy — every deployed copy is overwritten on
the next `make ai_clients` run. Tool-specific behaviour (hooks, skills,
subagents, memory layout, plan mode, sandboxing mechanics, ...) belongs in
that tool's own config file, never here — see the source-path table in
`ai_clients/CLAUDE.md`.

## CLI Commands — Use the RTK Proxy

For any command RTK supports (`git`, `gh`, `find`, `grep`, `ls`, `curl`,
`docker`, `pytest`, `cargo`, etc.), write the `rtk` prefix explicitly —
`rtk git status`, not `git status`. Some harnesses rewrite a bare command to
its `rtk` form transparently via a pre-execution hook; others do not —
either way, write the `rtk` form yourself in anything you author (agents,
skills, configs, scripts) so the behaviour does not depend on which harness
runs it, and so an approval prompt (if the harness has one) shows the form
you actually want allowlisted.

Commands RTK does not wrap run bare as normal (`sqlite3`, `jq`, `make`,
`python3`, `node`, etc.).

Exceptions where the bare binary is always correct:
- `command -v <tool>` availability checks
- Install instructions (`sudo apt install ...`)
- Prohibition examples in "Do Not" sections

### Never infer existence from a filtered or summarized listing

A token-saving proxy (rtk or otherwise) can collapse a real `ls`/`find`/
`grep` result to `(empty)` to save tokens — an empty-looking result is
**"unknown", never "absent."** Acting on a false negative silently skips
real files and repeatedly produces wrong "this is empty / does not exist"
claims.

- To check whether a path exists, read the file directly or list the
  directory through an unfiltered channel — never trust a filtered
  listing's silence as proof of absence.
- If a result looks empty but anything (memory, an index, prior knowledge)
  says the path should exist, verify directly before concluding absence.
- The same holds for test runners: the proxy can collapse `jest --coverage`
  to one `PASS`/`FAIL` line and rewrite `npx <bin>` into `npm run <bin>`. Never
  read a structured report (coverage, per-file lint) through a proxied runner;
  run package binaries by path (`./node_modules/.bin/<bin>`) or `rtk proxy`.

## Verify git writes actually landed

A `git commit`/`push`/`tag`/`branch -d/-D` can print full success — every
hook `Passed`, `[branch abc123] N files changed` — while a sandboxed or
containerized execution environment silently discards the ref update on
teardown. Never trust printed output alone for a git write:

- Never pipe a git write (`commit`, `push`, `tag`, `branch -d/-D`) through
  `tail`/`head`/`grep`. A hook rejection (lint, secret scan, formatter) or a
  rejected push can scroll off past a trimmed view while trailing lines make
  the run look clean.
- `$?` after a pipe is the last stage's status (`tail`), not git's: a
  rejected `git push ... | tail -3; echo $?` prints `0`. Use no pipe, or
  read `${PIPESTATUS[0]}` in the very next command.
- After any git write, confirm it landed by comparing refs, not exit
  codes:
  - commit: save `git rev-parse HEAD` before it; afterwards HEAD must
    differ from that value (an unchanged HEAD means it was rejected).
  - push: `git rev-parse HEAD` must equal the sha from
    `git ls-remote <remote> <ref>`, using the same remote and destination
    ref the push named, not an assumed `origin <branch>`.
  - tag: `git rev-parse --verify --quiet refs/tags/<tag>` must succeed,
    and a pushed tag must appear in `git ls-remote --tags <remote> <tag>`.
  - branch delete: `git rev-parse --verify --quiet refs/heads/<branch>`
    must fail.
- A read inside the writing sandbox, including `.git/refs/heads/<branch>`
  or `.git/logs/HEAD`, sees the same overlay the write did and can report
  a state teardown later discards. Run the confirmation from a view that
  survives teardown: the remote (`git ls-remote`) for anything pushed, and
  for local-only writes a later, separate invocation outside the sandbox
  (the caller, or the next session's first command).

## Version Control

- Conventional Commits: `feat:`, `fix:`, `chore:`, `test:`, `docs:`, `refactor:`.
- Atomic commits: one logical change per commit.
- Never commit secrets, credentials, or local config files.
- `.gitignore` before first commit.

## Numeric Precision

- Never use binary floating point (`float` in Python, `double`/`f64`/
  `float64` elsewhere) for exact decimal-domain values: money, counted
  quantities, accounting aggregates, and comparisons/equality on those.
  IEEE 754 binary floats cannot represent most decimal fractions exactly,
  and errors accumulate silently.
- Use the language-native decimal library instead: `Decimal` (Python),
  `decimal.js`/`big.js` (JS/TS), `BigDecimal` (Java/Kotlin),
  `shopspring/decimal` (Go), `rust_decimal` (Rust).
- Exception, numerical analysis: when the value is the output of an
  approximating method (series, quadrature, ODE solver, optimiser, special
  functions like `erf`/`exp`), use binary64 floating point. `Decimal` only
  gives more digits of an approximation that stays approximate; method
  error typically far exceeds binary64's ~1e-16 relative rounding error
  (high-order methods can approach it, and then representation error
  matters again), and catastrophic cancellation happens in `Decimal` too.
  The real axis is exact vs approximate, not money vs the rest. Where the
  two meet (a float price becoming a `Decimal` ledger entry), convert
  explicitly, choosing places and rounding mode, e.g.
  `Decimal(str(x)).quantize(Decimal("0.01"), rounding=ROUND_DOWN)`, never a
  bare `Decimal(x)` cast.
- Initialise from strings, not floats — `Decimal("0.1")`, never
  `Decimal(0.1)` — constructing from a float inherits the float's
  imprecision.
- Prefer truncation (`ROUND_DOWN`) over rounding when discarding excess
  digits: it is deterministic and never inflates a value, where rounding
  introduces a directional bias that compounds across bulk operations. Use
  `ROUND_HALF_UP`/`ROUND_HALF_EVEN` only when the domain explicitly demands
  it (tax, regulatory reporting).
- Ask for the required precision before writing `Decimal` code instead of
  hardcoding a default: money/prices → 2 places, exchange rates/
  percentages → 4 places, quantities/weights → 3 places.
