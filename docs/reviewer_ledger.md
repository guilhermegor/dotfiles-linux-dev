# Reviewer ledger (dotfiles-dev#488)

A SQLite record of every reviewer ask on the review ladder
(`coderabbitai > codex > qwen > kimi`) and every finding it produced, so
"is the ladder order right / is a rung effective / should another service
replace one" can be argued from data instead of one session's memory.

Implementation: `ai_clients/claude/hooks/lib/reviewer_ledger.sh`.
Tests: `tests/reviewer_ledger.bats`.

## Why two tables

"Number of reviews" collapses three different things: a review that found
nothing (clean code), a rung that was never asked (no data), and an ask a
rate limit refused (not a review). One counter would make an unasked rung
look identical to an ineffective one. So:

- **`ask`** — one row per ask: `rung`, `pr_number`, `head_sha`, `asked_at`,
  and an outcome (`refused` / `clean` / `found`).
- **`finding`** — one row per finding: its `ask_id`, claimed `severity`, a
  ternary `verdict` (`true` / `false` / `partial` — a finding can be real
  but overstated, e.g. #454's 200-PR-cap finding), and a closed-vocabulary
  `class`.

## The class vocabulary (closed, not free text)

```
auth-bypass  fail-open  shell-robustness  api-shape  docs-vs-code  test-gap  other
```

Defined in `REVIEWER_LEDGER_CLASSES` inside `reviewer_ledger.sh`, and
checked against it by the CLI's own validation before every insert.

⚠️ **Two places, not one, must change together when the vocabulary
changes.** The `finding.class` `CHECK` constraint inside
`reviewer_ledger_init`'s schema is a separate, hand-written literal list —
it is not derived from `REVIEWER_LEDGER_CLASSES` (SQLite has no way to read
a shell array into a `CHECK` clause). Adding a class only to the array lets
the CLI accept it, then SQLite rejects the insert at the `CHECK` boundary —
the two must be edited together. Additionally, `CREATE TABLE IF NOT EXISTS`
never alters an existing table's schema: a database created under an older
vocabulary needs an explicit migration (`ALTER TABLE finding` to redefine
the constraint, since SQLite can't `ALTER ... CHECK` directly — recreate the
table, copy the rows, and swap it in) before it will accept a newly added
class. `other` always requires a `--note`-worthy reason in practice, even
though the schema does not force one — re-classifying retroactively means
re-reading every finding, so pick a real class when one applies.

## Where the data lives

**Not in the repo.** The database is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/reviewer_ledger.db`
by default (override with `REVIEWER_LEDGER_DB`, which every test in
`tests/reviewer_ledger.bats` does to a tmp file) — covered by the existing
`backup_env`/external-drive backup, versioning it would churn on every
round.

## CLI

```bash
LEDGER=ai_clients/claude/hooks/lib/reviewer_ledger.sh

# idempotent — safe to call before every ladder run
"$LEDGER" init

# the deterministic half: rung, PR, head sha, outcome
ask_id="$("$LEDGER" ask --rung codex --pr 453 --sha aaa111 --outcome found | tail -1)"

# the one explicit model write: verdict + class, judged at resolution time
"$LEDGER" finding --ask-id "$ask_id" --severity major --verdict true --class fail-open \
    --note "optional free-text context"

# the three canned reports (counts only — never a computed ratio, see below)
"$LEDGER" report rung-effectiveness
"$LEDGER" report ladder-order
"$LEDGER" report zero-true --min-asks 5
```

`reviewer_ledger.sh` can also be `source`d — every subcommand is a plain
function (`reviewer_ledger_init`, `reviewer_ledger_record_ask`,
`reviewer_ledger_record_finding`, `reviewer_ledger_report`) so a caller that
already has the rung/PR/sha in hand (the ladder's own post path) can call
the writer directly instead of shelling out.

## The three reports

1. **`rung-effectiveness`** — per rung: ask count by outcome, finding count
   by verdict. Answers "is each rung effective" directly.
2. **`ladder-order`** — the same table ordered by true-finding count,
   descending — the argument for whether the ladder's current order still
   matches the value each rung has produced.
3. **`zero-true --min-asks N`** — rungs with at least N asks and zero true
   findings. Needs no significance test to be worth acting on.

All three print raw counts, never a computed percentage: the issue's own
point is that a raw accept/reject ratio ranks a reviewer wrong (CodeRabbit's
2/3 on #482 reads worse than a rung that missed a forgeable auth gate). A
percentage would also be a stored/compared float, which this repo's numeric
rule (`AGENTS.md`) disallows — printing `true=N` beside `asks=M` says the
same thing without one.

## What this does not do (yet)

The ladder's own post path (`ai_clients/claude/hooks/lib/reviewer_ladder.sh`)
and `s:dev-loop`'s finding-resolution step are not wired to call this
library in this change — both files were held by other in-flight PRs at
the time this was written. Wiring `reviewer_ledger_record_ask` into the
ladder's post path, and `reviewer_ledger_record_finding` into the point
where a thread's verdict is decided, is the natural next step and does not
require touching this file again.

At roughly 10 findings a day, statistical significance on "is the order
right" is months out — the near-term value is a rung with zero true
findings over N asks becoming visible, not a settled ranking.
