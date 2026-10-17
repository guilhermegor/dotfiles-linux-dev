# claudestatus top-bar (#734)

A GNOME Shell extension. The top bar shows the active account's name and session % (the account Claude Code is logged in as; falls back to the recommended account's session % when that is unknown or has no usage); the popover
shows four stacked account blocks (name, plan, unpaid badge, Session and Weekly bars with reset
countdowns, renewal, data age) and two buttons. `model.mjs` shapes the data.

- Opening the popover only reads stored files (`usage.json` next to the #733 billing cache,
  plus that cache, plus `~/.claude.json` or `$CLAUDE_CONFIG_DIR/.claude.json` for the active
  account: only `oauthAccount.organizationUuid` is used, matched against the snapshot's `orgUuid`;
  no match or two accounts in one org shows `active: unknown`). It never calls an API or scrapes.
- **Refresh usage** runs `refresh.mjs usage`, which calls the installed claudestatus
  `fetchAllUsage` (API, no browser) and saves the snapshot.
- **Refresh billing** runs `refresh.mjs billing`, which calls the installed, patched
  `fetchAllBilling` (re-scrapes only what the cache lacks).
- **+ Add account** (#751) opens a dialog (name). `refresh.mjs add <name>`
  rejects an empty name, a `/` or an existing account, then runs `claudestatus add <name>` (the
  browser login opens).
- Prerequisites: `claudestatus` installed and patched (`ai_clients/claude/lib/patch_claudestatus.sh`),
  `node` on PATH, GNOME Shell 46-48. Press **Refresh usage** once, because there is no snapshot
  before that.

## Install

```bash
DRY_RUN=1 bash distro_config/install_programs.sh   # preview; or pick the entry in the menu
```

`install_claudestatus_bar` (`distro_config/install_lib/system_utils.sh`) copies the extension to
`~/.local/share/gnome-shell/extensions/claudestatus-bar@dotfiles-dev/`, installs `model.mjs`,
`refresh.mjs`, `labels.mjs` and `lib/claudestatus_billing.mjs` under `~/.local/share/claudestatus-bar/` (where
`extension.js` reads them), and runs `gnome-extensions enable`. A new extension is only picked up
after a shell restart: `Alt+F2`, `r`, Enter on X11; log out and in on Wayland.

Logs: `journalctl -f -o cat /usr/bin/gnome-shell`.

## Test the data shaping

```bash
node --test ai_clients/claude/claudestatus_bar/test/model.test.mjs
```

## Logo

![token-budget hourglass](gnome-extension/icons/token-budget.svg)

An hourglass of tokens: amber top bulb = remaining, muted bottom bulb = spent, one token
falling. The panel uses the simplified monochrome `token-budget-symbolic.svg` (GNOME
recolours it); `token-budget.svg` is the full-colour mark. Drawn for this project
(#753) and intended to be reused under the MIT licence by the planned token-budget
spin-off.

## Remove

`uninstall_claudestatus_bar` disables the extension and deletes both directories. Optionally
`rm ~/.cache/claudestatus/usage.json`.
