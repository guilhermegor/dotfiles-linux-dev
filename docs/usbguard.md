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
3. Forces `ImplicitPolicyTarget=block` in `usbguard-daemon.conf`, points
   `IPCAccessControlFiles` at `/etc/usbguard/IPCAccessControl.d/` and writes a
   root-owned 0600 ACL file named after your user there. It is the file form of
   `usbguard add-user <user> --devices=modify,list,listen --policy=list
   --exceptions=listen` (written directly, not through the CLI, so it is
   deterministic and testable; the Debian postinst uses the same command
   before the daemon runs). `IPCAllowedUsers` is deliberately left alone: a user
   listed there with no ACL file gets every privilege, including
   `Parameters=modify`, so any process running as you could set
   `ImplicitPolicyTarget=allow`. For the same reason the installer **refuses**
   (exit 1, before any config change or daemon start) when your user belongs to
   a group listed in `IPCAllowedGroups` (Debian ships `root`; a group such as
   `plugdev` there would grant you full rights). The error names the group; fix
   it by removing the group from `IPCAllowedGroups` in `usbguard-daemon.conf`
   or removing yourself from the group. Under `DRY_RUN` it reports what it
   would refuse.
4. Runs `systemctl enable usbguard` and `systemctl restart usbguard`.

There are no prompts, and `DRY_RUN=1` prints every step without running it.

## Allow a device later

```bash
usbguard list-devices                 # blocked devices show as "block"
usbguard allow-device <id>            # this boot only
usbguard allow-device -p <id>         # -p makes the rule permanent
```

Neither needs sudo. In usbguard 1.1.2 `allow-device` (permanent or not) is the
`applyDevicePolicy` IPC call, gated only by `Devices=modify`
(`src/Library/IPCServerPrivate.cpp`, `registerHandler<IPC::applyDevicePolicy>`
with `Section::DEVICES`, `Privilege::MODIFY`; the `permanent` flag is not
checked separately). So your user can allow or block (including permanently)
devices that exist, but cannot change `Parameters` (such as
`ImplicitPolicyTarget`) or append or remove arbitrary policy rules
(`appendRule`/`removeRule` need `Policy=modify`, which is not granted).
Treat that as the trust boundary: a process running as you can permanently
allow a device that is plugged in.

An earlier version of this installer listed the user in `IPCAllowedUsers`;
re-running the installer removes that entry (root and other entries stay).

## Back out

```bash
sudo systemctl disable --now usbguard
```

Devices blocked while the daemon ran stay blocked until you replug them or
reboot. `uninstall_usbguard` does the same and also removes the package; it
deletes your ACL file and keeps the rest of `/etc/usbguard`, so a reinstall reuses your policy.

## Operator check (real hardware)

Unit tests stub `usbguard`, `systemctl` and `apt`, so the lockout-safety
claim needs one run on a real machine:

1. Run `install_usbguard`, then reboot.
2. Confirm every device that was plugged in at install time still works.
3. Plug in a new USB device and confirm `usbguard list-devices` shows it as
   `block`.
