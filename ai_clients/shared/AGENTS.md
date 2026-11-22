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

## Verify git writes actually landed

A `git commit`/`push`/`tag`/`branch -d/-D` can print full success — every
hook `Passed`, `[branch abc123] N files changed` — while a sandboxed or
containerized execution environment silently discards the ref update on
teardown. Never trust printed output alone for a git write:

- Never pipe `git commit` through `tail`/`head`/`grep`. A hook rejection
  (lint, secret scan, formatter) can scroll off past a trimmed view while
  trailing `Passed` lines make the run look clean.
- After any git write, confirm it landed: run it with full output, then in
  the same step `echo "===EXIT=$?==="` followed by `git log --oneline -1`,
  and check that HEAD actually moved.
- If still unsure, read `.git/refs/heads/<branch>` (or `.git/logs/HEAD`)
  directly — a command run through the same sandboxed environment can
  report a state that was never durably committed.

## Version Control

- Conventional Commits: `feat:`, `fix:`, `chore:`, `test:`, `docs:`, `refactor:`.
- Atomic commits: one logical change per commit.
- Never commit secrets, credentials, or local config files.
- `.gitignore` before first commit.

## Numeric Precision

- Never use `float` for values where precision matters (money,
  measurements, aggregations, comparisons) — IEEE 754 binary floats cannot
  represent most decimal fractions exactly, and errors accumulate silently.
- Use the language-native decimal library instead: `Decimal` (Python),
  `decimal.js`/`big.js` (JS/TS), `BigDecimal` (Java/Kotlin),
  `shopspring/decimal` (Go), `rust_decimal` (Rust).
- Exception, numerical analysis: when the value approximates an irrational
  (`erf`, `exp`, quadrature, ODE solutions, optimisation), use `float`.
  `Decimal` only gives more digits of an approximation that stays
  approximate; method truncation (1e-7 to 1e-9) dwarfs representation error
  (1e-16), and catastrophic cancellation happens in `Decimal` too. The real
  axis is exact vs approximate, not money vs the rest. Where the two meet
  (a float price becoming a `Decimal` ledger entry), the conversion is an
  explicit rounding decision, never a bare cast.
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
  percentages → 4 places, quantities/weights → 3 places, scientific
  measurements → 10 places.
