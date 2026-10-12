# claudestatus top-bar prototypes (#734)

Two throwaway prototypes of the same popover, so the owner can pick a technology. Not wired
into the installer, the menu or the shortcut removal.

Both show what `model.mjs` returns: the top bar gets the recommended account's session %, the
popover gets four stacked account blocks (name, plan, unpaid badge, Session and Weekly bars
with reset countdowns, renewal, data age) and two buttons.

- Opening the popover only reads stored files (`usage.json` next to the #733 billing cache,
  plus that cache). It never calls an API or scrapes.
- **Refresh usage** runs `refresh.mjs usage`, which calls the installed claudestatus
  `fetchAllUsage` (API, no browser) and saves the snapshot.
- **Refresh billing** runs `refresh.mjs billing`, which calls the installed, patched
  `fetchAllBilling` (re-scrapes only what the cache lacks).
- Prerequisites: `claudestatus` installed and patched (`ai_clients/claude/lib/patch_claudestatus.sh`),
  `node` on PATH. Press **Refresh usage** once, because there is no snapshot before that.

Set `R` to this directory first:

```bash
R=<path-to-checkout>/ai_clients/claude/claudestatus_bar
```

## Test the data shaping

```bash
node --test $R/test/model.test.mjs
```

## 1. GNOME Shell extension

```bash
ln -s $R/gnome-extension ~/.local/share/gnome-shell/extensions/claudestatus-bar@dotfiles-dev
gnome-extensions enable claudestatus-bar@dotfiles-dev
```

A new extension is only picked up after a shell restart: log out and in on Wayland, or
`Alt+F2`, `r`, Enter on X11. For a throwaway window without logging out:
`dbus-run-session -- gnome-shell --nested --wayland`.

Logs: `journalctl -f -o cat /usr/bin/gnome-shell`.

Remove:

```bash
gnome-extensions disable claudestatus-bar@dotfiles-dev
rm ~/.local/share/gnome-shell/extensions/claudestatus-bar@dotfiles-dev
```

## 2. AppIndicator + GTK4 window

Needs system PyGObject with Gtk 3 + Ayatana AppIndicator and Gtk 4 + libadwaita
(`/usr/bin/python3`; the pyenv python has no `gi`), and GNOME's AppIndicator shell extension
enabled, otherwise the tray icon is not drawn
(`sudo apt install gir1.2-ayatanaappindicator3-0.1 gir1.2-adw-1`,
`gnome-extensions enable ubuntu-appindicators@ubuntu.com`).

```bash
/usr/bin/python3 $R/appindicator/tray.py &
```

Click the icon, then "Open claudestatus" (the GTK4 window). The tray is a separate process from
the window because AppIndicator is GTK3 and libadwaita is GTK4. Preview the window alone:
`/usr/bin/python3 $R/appindicator/window.py`.

Remove: `pkill -f claudestatus_bar/appindicator/tray.py`.

## Clean up the shared data (optional)

```bash
rm ~/.cache/claudestatus/usage.json
```

## Trade-offs the owner is picking between

| | GNOME extension | AppIndicator + GTK4 |
|---|---|---|
| Popover | native, anchored to the icon | a normal window, opened from the tray menu |
| Dependencies | none beyond the shell | PyGObject, Ayatana, the AppIndicator shell extension |
| Shell upgrades | `shell-version` must be bumped per release | independent of the shell |
| Reload during dev | shell restart | restart the process |
