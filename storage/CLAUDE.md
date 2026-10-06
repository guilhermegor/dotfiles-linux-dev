# storage/CLAUDE.md

## Purpose

All storage concerns in one place: mounting, encryption, formatting, recovery,
backup, and capacity analysis.

## Scripts

| File | What it does |
|------|-------------|
| `mount_disks.sh` | Auto-mount external drives to `/mnt/auto/` |
| `vault.sh` | Encrypt a device with VeraCrypt (AES-256 + SHA-512) |
| `format_hard.sh` | Full (slow) format with `shred` before filesystem creation |
| `format_neat.sh` | Quick format — partition table + filesystem only |
| `data_recovery.sh` | Attempt file recovery with `testdisk` / `photorec` |
| `check_legitimity.sh` | Verify drive health via SMART data |
| `backup_env.sh` | GUI-driven, gpg-encrypted backup of git-ignored `.env` files + `rclone.conf` |
| `restore_env.sh` | Decrypts and restores the bundle `backup_env.sh` produces |
| `storage_hiato.sh` | Detect SSDs, SATA/NVMe slots, report theoretical max capacity |

## Conventions

- **`print_status <level> <msg>`** with the standard color vars (`RED` `GREEN` `YELLOW` `BLUE` `CYAN` `MAGENTA` `NC`).
- Destructive operations (format, encrypt) must print a `RED` warning and prompt for
  explicit confirmation before proceeding.
- Always unmount before formatting or encrypting: `sudo umount /dev/$device*`.
- Use `lsblk -o NAME,SIZE,TYPE,MOUNTPOINT` to list devices before prompting.
- Mounted media lives under `/media/$USER/<drive-name>/`.
- **Diagnostic / read-only scripts** (`storage_hiato.sh`) must never write to `/dev/*`
  or modify partition tables. Require root with `[ "$(id -u)" -ne 0 ]` guard.

## Encrypted env backup (`backup_env.sh` / `restore_env.sh`)

- Reads `CLAUDE_BACKUP_DIR` from `~/.claude/.env`, same as `c:backup-env` /
  `c:restore-env` — but this is a separate, zenity-driven, whole-machine flow
  (scans every repo under `~/github`), not the per-repo slash command.
- `backup_env.sh` lets the operator pick which git-ignored `.env` files (and,
  when present, `~/.config/rclone/rclone.conf`) to include, then bundles them
  into **one** tar and encrypts it with a symmetric passphrase
  (`gpg --symmetric --cipher-algo AES256`), prompted twice via zenity's hidden
  entry. The passphrase is fed to `gpg` over stdin (`--passphrase-fd 0`,
  `--pinentry-mode loopback`) — it never appears in argv, `ps`, or shell
  history. Only the resulting `env_bundle_<timestamp>.tar.gpg` is written
  under `$CLAUDE_BACKUP_DIR/env_bundle/`; the script refuses to write
  anything else there.
- **Migration:** a pre-#367 backup left plaintext copies under
  `$CLAUDE_BACKUP_DIR/env_files/` (gzip is compression, not encryption).
  Every backup run reports any such files found, with exact paths, so the
  owner can delete them by hand — they are never deleted automatically.
- `restore_env.sh` decrypts the chosen bundle, restores each file mode `600`,
  and never overwrites an existing file (it may hold a newer, working
  secret) — a conflict is reported as skipped, not overwritten.
- After restoring `rclone.conf`, it runs a cheap `rclone lsd <remote>:
  --max-depth 1` check. OneDrive refresh tokens expire after disuse, so a
  failure here is expected, not an error — the summary points at
  `rclone config reconnect <remote>:` instead of leaving a silently broken
  mount.
- Never touches rclone's own config password on the live file — that would
  encrypt the file the systemd mount unit (#361) reads at boot, which it has
  no way to unlock.

## Adding a new script

1. Create `storage/<action>.sh`.
2. Use the standard color vars and `print_status`.
3. Guard destructive operations with confirmation prompts.
4. Wire into `make` if it should be part of the setup flow.
