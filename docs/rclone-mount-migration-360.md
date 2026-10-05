# Replacing Insync with an on-demand rclone mount (issues #360, #365)

## Why

Insync mirrors every remote file to disk, forever, whether or not it is ever opened. Measured on
this machine, 2026-09-13:

| what | size |
|---|---|
| `~/Insync/<account>/OneDrive/` (one **OneDrive** account) | **1.3 T** |
| `~/.config/Insync/` (metadata/db) | **17 G** |
| root filesystem | 1.8 T total, **1.6 T used, 188 G free (90 %)** |

`rclone mount` with a VFS cache serves the directory listing instantly and downloads a file only
when something opens it, with a hard ceiling on the cache (`--vfs-cache-max-size 10G`). A 10 G
cache ceiling replaces a 1.3 T mirror.

## What this repo automates

- `install_rclone` (`distro_config/install_lib/sharing.sh`) — installs the `rclone` package via
  the distro's package manager. Never runs `rclone config`, never writes anything under
  `~/.config/rclone/`.
- `install_rclone_config [remote] [type] [region]` (same file, issue #365) — writes the
  non-secret skeleton of `~/.config/rclone/rclone.conf` (mode `600`):
  ```ini
  [onedrive]
  type = onedrive
  region = global
  ```
  Refuses to overwrite an existing `rclone.conf` — it may already hold a working token. Args
  fall back to the `RCLONE_REMOTE` / `RCLONE_TYPE` / `RCLONE_REGION` env vars, then to
  `onedrive` / `onedrive` / `global`. When stdin is a terminal it then runs
  `rclone config reconnect <remote>:` for the one-time browser sign-in; an unattended run (no
  tty) skips that step and prints the command instead of hanging or failing. It never runs the
  interactive `rclone config` wizard, so rclone's "set configuration password" option is never
  offered — an encrypted config can't be unlocked by the systemd mount at boot.
- `install_rclone_mount_unit [remote] [mountpoint]` (same file) — writes
  `~/.config/systemd/user/rclone-<remote>.service` from the repo-tracked template at
  `distro_config/dotfiles/rclone/rclone-mount.service.template`, **creating `<mountpoint>` when
  it is absent**. Refuses (does not warn) when `<mountpoint>` already exists, is non-empty and is
  not a live mount of the unit, and always refuses `~/Insync` regardless of emptiness. Idempotent
  (#649): when `<mountpoint>` is already a live mount of the unit it reports "already mounted",
  rewrites the unit file only if its content would change, and returns 0. It suggests
  `systemctl --user restart` only for a functional change; a comment-only diff (comment and
  blank lines ignored on both sides) is rewritten silently as "updated comments only" (#651), since
  a restart remounts the live mount. Never enables or starts the unit. Args
  fall back to `RCLONE_REMOTE` / `RCLONE_MOUNT_POINT`, then to `onedrive` / `~/OneDrive` (issue
  #365) — so `install_rclone_mount_unit` with no arguments reproduces the `mkdir -p ~/OneDrive`
  + `install_rclone_mount_unit onedrive ~/OneDrive` sequence that was previously done by hand.
- `uninstall_insync <remote> [account-dir]` (same file) — the 5-step ordered removal below, as a
  single function. Not registered in `INSTALL_REGISTRY` (a registry entry runs during Full
  Installation too, which would fight `install_insync` — see #342), so it is invoked directly:

  ```bash
  bash -c 'source distro_config/install_lib/sharing.sh; uninstall_insync <remote> <account-dir>'
  ```

  `sharing.sh` sources its sibling `_common.sh` itself when `print_status` is not already
  defined, so this one-file form works (#599). Before that, `command_exists` was undefined,
  `insync quit` was never called, and step 1 refused because Insync was still running.

### Where the operator is asked (issue #365)

`install_lib/sharing.sh` never prompts (#339 — an `install_*` function must run unattended).
The non-secret questions (remote name, type, region, Personal/Business, mount point) are asked
only by `prompt_rclone_choices` in `distro_config/install_programs.sh`'s **Custom Installation**
path, right before the `install_rclone` entry runs; the answers are exported as
`RCLONE_REMOTE` / `RCLONE_TYPE` / `RCLONE_REGION` / `RCLONE_ACCOUNT_KIND` / `RCLONE_MOUNT_POINT`
and consumed by `install_rclone_config` and `install_rclone_mount_unit`, which
`run_rclone_followups` runs right after `install_rclone`. **Full Installation and any
unattended run take the defaults silently** — no question is asked, and the two followup
functions just fall back to `onedrive` / `onedrive` / `global` / `~/OneDrive`.

## Operator runbook — the 5 mandatory ordered steps

⚠️ Deleting `~/Insync/` while Insync is running propagates the deletion to OneDrive. The
order below is mandatory; `uninstall_insync` enforces it by refusing to continue when a
precondition fails.

0. **Pre-check with Insync's own tools, before running anything.** While Insync is still up:

   ```bash
   insync status
   insync error list
   insync conflict list
   ```

   These are the fastest way to learn what step 2 will trip over. On this machine they showed
   207 symlink upload errors (`rclone check` skips symlinks without `-L`/`-l`, so those are
   not a real gap) and 106 local-only conflicts ("edited locally, deleted in cloud"), which
   `rclone check` lists as missing on the remote. Decide about the conflicts in Insync's UI
   first — they are the files most likely to be the only copy.
1. **Quit Insync and disable it from starting.** `uninstall_insync` calls `insync quit`, then
   polls `pgrep insync` once a second for up to `INSYNC_QUIT_TIMEOUT` seconds (default 30).
   `insync quit` returns 0 yet can be ignored while the daemon is busy — measured: the main
   process (`insync start --no-daemon`, watching 3.87 M files) was still alive 2 minutes
   later. If it survives, `uninstall_insync` sends SIGTERM (never SIGKILL) and polls for up
   to `INSYNC_TERM_TIMEOUT` seconds (default 60) more. It then removes
   `~/.config/autostart/insync.desktop` if present. Refuses (exit 1) only if an insync
   process still survives after both waits.
2. **Verify local-to-remote integrity while the local copy still exists.** With the daemon
   stopped, `uninstall_insync` runs
   `rclone check <account-dir> <remote>: --one-way --size-only --missing-on-dst <file> --differ <file>`
   and logs the result. The local directory is deliberately the SOURCE argument and the remote
   the destination: `--one-way` means "source files must exist on destination" (`rclone check
   --help`), so the check must prove every **local** file exists on the **remote** — the
   guarantee `rm -rf <account-dir>` actually needs. Checking it the other way round (remote as
   source, as an earlier version of this function did — issue #577) only proves the opposite,
   that every remote file exists locally, which lets a file Insync never uploaded (a pending
   upload, an excluded path, a conflict copy) pass silently and then get deleted. `--size-only`
   skips hashing the full tree (hours of disk I/O for 1.3 T with no progress output otherwise).
   Refuses — exit 1, before any deletion — on a non-zero exit **or** a non-empty
   `--missing-on-dst` / `--differ` file, naming both files so the discrepancy can be inspected
   before re-running.

   **Resolving a refusal.** Files in `uninstall_insync_missing_on_dst.txt` exist only locally
   (typically the "edited locally, deleted in cloud" conflicts above). Upload exactly those,
   then re-check with hashes — `--size-only` can pass a same-size file whose content differs:

   ```bash
   rclone copy <account-dir> <remote>: --files-from <log-dir>/uninstall_insync_missing_on_dst.txt
   rclone check <account-dir> <remote>: --one-way \
       --missing-on-dst /tmp/missing.txt --differ /tmp/differ.txt
   ```

   Drop `--size-only` on that re-check so content is compared by hash; both output files must
   come back empty. Then re-run `uninstall_insync` (which repeats its own check). Entries in
   `uninstall_insync_differ.txt` need a human decision on which side wins before copying.
3. **Uninstall the package.** `sudo apt remove --purge insync`, verified against
   `dpkg -l | grep insync` being empty. Touches only the local machine — OneDrive keeps
   everything regardless of which client is installed.
4. **Delete `~/Insync/` and `~/.config/Insync/`.** Gated behind the explicit
   `INSYNC_CONFIRM_DELETE=1` environment variable — it is the one step that destroys local data,
   and it never runs just because steps 1-3 passed. Without it, `uninstall_insync` reports what it
   would delete and exits 0 without touching anything.
5. **Re-check the remote after deletion.** `rclone lsjson <remote>: --stat`, logged for a
   before/after comparison.

## Steps that remain manual (cannot be automated safely)

- **The browser sign-in** — `rclone config reconnect <remote>:` is a real OAuth flow this repo
  has no business scripting further than invoking it, and no token may ever be committed.
  `install_rclone_config` runs it automatically in an interactive session; an unattended run
  prints the command instead.
- **Choosing the mount point path** — the operator (or the Custom Installation questions) picks
  where the mount lives; it must not be `~/Insync` until step 4 above has run.
  `install_rclone_mount_unit` creates the directory once it's chosen, but never chooses it.
- **Enabling the unit** — `install_rclone_mount_unit` only writes the unit file. After reviewing
  it, `make rclone_mount` (`enable_rclone_mount_unit [remote] [mountpoint]`, issue #647) runs
  `systemctl --user daemon-reload` + `enable --now`. It refuses unless the unit exists, the remote
  answers `rclone lsd <remote>: --max-depth 1` (present and authenticated), and the mount point
  is an existing empty directory other than `~/Insync`; then it waits (`RCLONE_MOUNT_WAIT`, default
  30 s) for `mountpoint -q` and prints the last `journalctl --user -u` lines if the mount never
  appears. Already enabled, active and mounted is a no-op. `run_rclone_followups` runs the same
  step unattended in `make run` (#649) — no prompt, TTY or not; a refusal (for example an
  unauthenticated remote, with its `rclone config reconnect` hint) only warns and the rest of
  the install carries on.
- **The actual `INSYNC_CONFIRM_DELETE=1` run** — deleting 1.3 T of the owner's data is a
  human decision, not a default.
- **Verifying the cache ceiling holds** — read a file larger than 10 G through the mount, then
  confirm `du -sh ~/.cache/rclone/` stays under the cap. This needs the mount to actually be
  live.

## Machine state that points into `~/Insync` — migrate it before step 4

The tree is not only data; other things hold paths into it. Found on this machine:

- **Super+B (Backup External SSDs)** — `~/.config/backup-external-ssd.conf` holds
  `LAST_DEST=~/Insync/<account>/OneDrive/Workspace/!BACKUP/External Storage`.
  After step 4 that path is gone, and the backup script's `mkdir -p` would happily re-create it on
  the local disk and write the archive there — a backup that looks cloud-bound and is not.
  `storage/backup_external_ssd.sh` now refuses to pre-fill a destination whose parent no longer
  exists and says so in the prompt, so the migration surfaces as a question instead of a silent
  local write. Point it at the new mount path on the first run after migrating.
- ⚠️ **Do not write large archives through the mount.** `--vfs-cache-max-size 10G` bounds the
  cache, and a write larger than the ceiling has nowhere to land. For the SSD backup, write the
  zip to local scratch and `rclone move` it to the remote, rather than zipping straight into the
  mount point.

Before running step 4, grep for other holders:

```bash
grep -rIl "$HOME/Insync" ~/.config ~/.local/share ~/.local/bin 2>/dev/null
```

## Trade-offs to keep in mind

- **Offline access changes.** Insync always had every file on disk; the mount only has what is in
  the cache. Pin any folder that must be available offline with a scheduled `rclone sync` into a
  real local directory, or accept the loss explicitly.
- Applications that scan whole trees (indexers, backup tools, some editors) pull files through
  the mount and can fill the cache — check which of those are running before relying on the
  ceiling.
- `--vfs-cache-mode full` needs writable space in `~/.cache/rclone`, which sits on the same
  90 %-full root filesystem the 10 G cap is meant to protect.

## Alternatives considered

- **OneDriver** — OneDrive-only, so it *is* applicable here, but it offers no cache ceiling: it
  caches whatever is opened with no `--vfs-cache-max-size` equivalent. The 10 G cap is the point
  of this migration, so `rclone` wins on the one axis that motivated it.
- **Celeste** — GUI, on-demand, but fewer knobs than rclone's VFS cache; worth revisiting only if
  the mount proves awkward to live with.
- **Keeping Insync with selective sync** — solves disk usage but keeps a per-seat paid client for
  something a mount does for free, and still mirrors whatever is selected.
