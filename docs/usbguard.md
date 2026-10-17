# USBGuard (block unknown USB devices)

`install_usbguard` (registered in the install menu, no launcher and no GNOME
folder) installs `usbguard` and turns on enforcement with
`ImplicitPolicyTarget=block`: a USB device that was not plugged in at install
time is blocked until you allow it.

## What the installer does, in order

1. Installs the `usbguard` package.
2. Writes `/etc/usbguard/rules.conf` with `usbguard generate-policy`, so the
   keyboard, mouse, Logitech receiver, YubiKey and dock connected right now are
   all allowed. This happens **before** the daemon is enabled: a daemon that
   starts on an empty `rules.conf` blocks everything, including the keyboard.
   An existing `rules.conf` that has at least one rule is never overwritten
   (the Debian/Ubuntu package already seeds it on first install, so on those
   systems the file the package wrote is kept). An empty generated policy
   aborts the install before the daemon is touched.
3. Forces `ImplicitPolicyTarget=block` in `usbguard-daemon.conf` and adds your
   user to `IPCAllowedUsers` (existing entries are kept), so you can list and
   allow devices without root.
4. Runs `systemctl enable usbguard` and `systemctl restart usbguard`.

There are no prompts, and `DRY_RUN=1` prints every step without running it.

## Allow a device later

```bash
usbguard list-devices                 # blocked devices show as "block"
usbguard allow-device -p <id>         # -p makes the rule permanent
```

## Back out

```bash
sudo systemctl disable --now usbguard
```

Devices blocked while the daemon ran stay blocked until you replug them or
reboot. `uninstall_usbguard` does the same and also removes the package; it
keeps `/etc/usbguard`, so a reinstall reuses your policy.

## Operator check (real hardware)

Unit tests stub `usbguard`, `systemctl` and `apt`, so the lockout-safety
claim needs one run on a real machine:

1. Run `install_usbguard`, then reboot.
2. Confirm every device that was plugged in at install time still works.
3. Plug in a new USB device and confirm `usbguard list-devices` shows it as
   `block`.
