---
paths:
  - "**/*.sh"
  - "**/*.bash"
---

# Bash / Shell Preferences

> **Priority rule:** These are personal Bash defaults — they apply to every `*.sh`
> and `*.bash` file. Whenever a project-level CLAUDE.md (or any instruction inside the
> active repository) conflicts with anything here, the project context takes precedence.
> Treat this file as a fallback, not a mandate — and never let "best practice in general"
> silently override a project-specific rule.

## Write to pass the shellcheck gate

CI lints every `*.sh` with `shellcheck --severity=warning --exclude=SC1091`
plus a `bash -n` parse check. Write code that is clean at that level the
first time — do not lean on a later cleanup pass. The recurring warnings
below each have a single canonical fix; apply it as you write.

Only `SC1091` (can't follow sourced file) is excluded globally, because
scripts source siblings via runtime paths shellcheck can't resolve. Any
other `disable` must be **line-scoped** and carry a one-line reason comment.

## In a bats test body, never a bare `! <cmd>` — it isn't an assertion

`set -e` never aborts on a command whose exit status is inverted with `!` —
that is an explicit shell exemption, not a bats quirk. bats takes a test's
verdict from `set -e` plus the LAST command's status, so `! <cmd>` is a real
assertion only when it is the test's very last statement — and "it is last
today" is exactly the property that silently stops being true the moment
someone appends another assertion below it:

```bash
# ❌ six of these could never fail — only the last one is a real assertion
@test "no mutation happened" {
    run_reconcile
    ! grep -q 'issue edit'    "$GH_LOG"   # ← passes no matter what the log holds
    ! grep -q 'item-edit'     "$GH_LOG"   # ← passes no matter what the log holds
    ! grep -q 'issue comment' "$GH_LOG"   # ← real, only because it is last
}

# ✅ run captures the status instead of letting `!` swallow it; [ … ] is a
# plain command set -e does police
refute_gh() {
    run grep -q -- "$1" "$GH_LOG"
    [ "$status" -ne 0 ]
}
```

`[[ ! "$output" == *x* ]]` is equally safe — the negation sits *inside* the
test command rather than inverting it. Add a per-suite `refute_*` helper
(`refute_gh`, `refute_repo_grep`, …) when a suite repeats the pattern.

Write it correctly the first time — `tests/bats_negation_gate.sh` rejects
any bare `! <cmd>` inside a `@test` body in `tests/*.bats`, wired into both
`make test` and CI, with no last-line exemption (dotfiles-linux-dev#380).

## Status output: always `print_status`, never raw `echo`/`printf`

All user-facing status and operational logging goes through
`print_status <level> <message>` (defined in `lib/common.sh`). Never use
bare `echo`/`printf` for status, progress, success, or error messages —
`print_status` colorises consistently, sends errors to stderr, and appends
a timestamped line to `$LOG_FILE` when one is set.

```bash
# ✅
print_status "info"    "Installing act via Homebrew..."
print_status "success" "act installed"
print_status "error"   "Download failed — check $LOG_FILE"   # → stderr + log

# ❌ no colour, no stderr routing, no log line
echo "Installing act..."
echo "ERROR: download failed" >&2
```

Levels (use the right one — they map to colour + routing):

| Level | Use for | Routing |
|-------|---------|---------|
| `success` | a completed action | stdout |
| `error` | a failure the user must see | **stderr** |
| `warning` | a recoverable / skipped condition | stdout |
| `info` | progress narration | stdout |
| `config` | a chosen setting / value being applied | stdout |
| `debug` | verbose diagnostics | stdout |
| `section` | a banner separating major phases | stdout |

Plain data the caller will parse (a path, a captured value) is **not** status —
that may still go to stdout via `echo`/`printf`. The rule is about *status*,
not all output.

## Every script must have `print_status` available — source it or inherit it

`print_status` is non-optional (see above). Every `*.sh` / `*.bash` file must be
able to call it. Two acceptable ways to make it available:

1. **Source the canonical helper** (preferred) — `lib/common.sh` is the single
   source of truth (it defines `print_status`, the color vars, the idempotent
   re-source guard, the source-only guard, and the optional `LOG_FILE` tee):

   ```bash
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   source "$SCRIPT_DIR/lib/common.sh"      # adjust the relative path as needed
   ```

2. **Ship the helper alongside the script** when it is distributed standalone and
   cannot reach the repo's `lib/common.sh` (e.g. copied into a generated project):
   copy `lib/common.sh` next to it and source it. Never silently fall back to bare
   `echo` for status.

Do not duplicate the implementation in callers — reference `lib/common.sh`. Only
the re-source guard variable name may differ per project (e.g.
`_DOTFILES_COMMON_LOADED` → `_BX_COMMON_LOADED`).

## Structure: wrap logic in functions, drive from `main`

No top-to-bottom procedural scripts. Every script organises its logic into named
functions and ends with a single `main` entrypoint invoked as `main "$@"`. This
keeps each step named, testable, and greppable, and makes control flow explicit.

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

do_thing() {
    print_status "info" "Doing the thing..."
    # ...
}

main() {
    do_thing
    print_status "success" "Done"
}

main "$@"
```

Exception: a pure library file meant only to be sourced (no entrypoint) defines
functions and uses the source-only guard instead of a `main`.

## `cd … || return` in sourced libs, `cd … || exit` only in standalone scripts

Every `cd` needs a failure guard (SC2164) — but which one depends on how the
file runs:

- Files **sourced** by an orchestrator (e.g. `distro_config/install_lib/*.sh`,
  `distro_config/install_coding_lib/*.sh`, `ai_clients/.../lib/*.sh`) must use
  `cd … || return 1`. Their `cd`s live inside functions, and `exit` would kill
  the **parent** shell — aborting the whole menu, not just the one install.
- **Standalone** scripts run directly (`drivers/*.sh`, top-level `cd` outside any
  function) use `cd … || exit 1`.

```bash
# ✅ inside a sourced install_* function
install_foo() {
    cd "$DOWNLOADS_DIR" || return 1
    ...
    cd - > /dev/null || return 1
}

# ✅ standalone script, top-level
cd /home/"$USER" || exit 1
```

When in doubt: is the file `source`d anywhere? If yes, `return`.

## Split `local x=$(cmd)` (SC2155)

`local x=$(cmd)` always succeeds — the `local` keyword swallows `cmd`'s exit
status, so `set -e` and `$?` never see a failure. Declare, then assign:

```bash
# ❌ exit code masked
local loop_device=$(losetup --list | grep "$img" | awk '{print $1}')

# ✅ failures are visible
local loop_device
loop_device=$(losetup --list | grep "$img" | awk '{print $1}')
```

## Arrays: `mapfile`, and the membership-test idiom

- **Building an array from command output** — use `mapfile -t`, never
  `arr=($(…))` (SC2207 — re-splits on IFS and glob-expands every element):

  ```bash
  # ❌
  backup_files=($(ls -td "$HOME"/backup_* 2>/dev/null))
  # ✅
  mapfile -t backup_files < <(ls -td "$HOME"/backup_* 2>/dev/null)
  ```

- **"Is element in array?"** — use a glob substring match, not `=~`
  (SC2199 `[@]` concatenates inside `[[ ]]`; SC2076 a quoted `=~` RHS is
  matched literally anyway):

  ```bash
  # ❌
  if [[ ! " ${apps[@]} " =~ " '$item' " ]]; then
  # ✅ same behaviour, zero warnings
  if [[ ! " ${apps[*]} " == *" '$item' "* ]]; then
  ```

## Iterate globs, never `ls` output

`for x in $(ls …)` (SC2045) and `ls … | grep …` (SC2010) break on spaces and
odd filenames. Glob directly and guard the empty case:

```bash
# ❌
for part in $(ls /dev/${drive}[0-9]* 2>/dev/null); do
# ✅
for part in /dev/"${drive}"[0-9]*; do
    [ -e "$part" ] || continue   # glob matched nothing
    ...
done

# "does any subdir exist?" — ❌ ls … | grep -q .
if compgen -G "$cache_dir/*/" > /dev/null 2>&1; then
```

## `sudo` with redirects and the dry-run wrapper

- **The redirect is opened by the calling (non-root) shell, not by `sudo`**
  (SC2024). When the target is a user-owned path like `$LOG_FILE` in `$HOME`,
  the warning is a false positive — do **not** rewrite it to `sudo tee`.
  Suppress it line-scoped with a reason:

  ```bash
  # $LOG_FILE is under $HOME (user-owned); the user shell opens the redirect.
  # shellcheck disable=SC2024
  if sudo docker run hello-world &>> "$LOG_FILE"; then
  ```

- This repo gates destructive commands behind `run_or_echo` for `DRY_RUN=1`.
  Wrapping `sudo …` in `run_or_echo` is the preferred form **and** sidesteps
  SC2024 (shellcheck sees the wrapper, not `sudo`). Prefer it for any command
  that mutates state:

  ```bash
  run_or_echo sudo "$PACKAGE_MANAGER" list upgrades >> "$LOG_FILE" 2>&1 || true
  ```

## Quote command substitutions in argument lists (SC2046)

Unquoted `$(…)` word-splits. Quote it when it forms part of an argument:

```bash
sudo apt install linux-headers-"$(uname -r)" build-essential
```

## Source-only guard and shebang

- Every script starts with `#!/bin/bash` (SC2148 — no shebang means shellcheck
  can't pick a dialect, and the parse check has no target shell).
- Library files meant to be **sourced**, not executed, guard against direct
  invocation:

  ```bash
  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
      echo "<file> is meant to be sourced, not executed." >&2
      exit 1
  fi
  ```

## When in doubt

If a shell change behaves unexpectedly or trips CI:

1. Run `shellcheck --severity=warning --exclude=SC1091 <file>` and `bash -n <file>`
   locally before pushing — the same gate CI runs.
2. A masked failure usually traces to `local x=$(…)` (split it) or a missing
   `cd … || return/exit`.
3. An array misbehaving on odd input is almost always `arr=($(…))` or an
   `ls`-driven loop — switch to `mapfile` / glob.
4. A `cd` that "works locally but breaks the menu" is `exit` where it should be
   `return` in a sourced lib.
