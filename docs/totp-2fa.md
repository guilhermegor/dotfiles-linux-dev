# Optional TOTP 2FA (libpam-google-authenticator)

`install_google_authenticator` (registered in the install menu) installs
`libpam-google-authenticator` and enables a `pam-auth-update` profile
(`distro_config/pam/google-authenticator`, installed to
`/usr/share/pam-configs/google-authenticator`). It never edits
`/etc/pam.d/*`: `pam-auth-update` regenerates `common-auth`, and the profile
lands there as an `Additional` module that runs after `pam_unix`.

The module uses `nullok`, so a user who has not enrolled still logs in with
the password alone. Enabling the profile before enrolling cannot lock anyone
out. Enrollment is never automated.

## What gets a code

Everything that includes `common-auth`: `sudo`, GDM login and lock screen,
TTY `login`, `su`, polkit prompts, and `sshd`. The last three are side
effects of "all of them", not extra opt-ins.

SSH is conditional. The installer first removes any earlier copy of its own
drop-in (under the current and the pre-`10-` name), so a re-run judges the
host's own config instead of its own leftover `KbdInteractiveAuthentication
yes`. It then reads the effective config with `sudo sshd -T` and counts
password logins as on when `passwordauthentication yes`, or
`kbdinteractiveauthentication yes` together with `usepam yes` (the drop-in
forces `UsePAM yes`, so keyboard-interactive under `UsePAM no` would be a
brand-new PAM password path). `sshd -T` without `-C` shows only global
values, so `Match` blocks are not considered.

- **Key-only host** (neither condition holds, e.g. cloud images that set
  `PasswordAuthentication no`; stock Ubuntu Server does *not* qualify, since
  sshd defaults to `PasswordAuthentication yes`): the drop-in
  is skipped with a warning, and ssh is left unchanged. Enabling
  keyboard-interactive here would reopen a password login path, and because
  of `nullok` an unenrolled account would get in with the password alone.
  The same happens if the `sshd -T` read fails (fail closed), or if
  openssh-server is not installed. A running sshd keeps its old config until
  it is reloaded, so after a re-run that removed the drop-in, run
  `sudo systemctl reload ssh`.
- **Password logins already on:** the drop-in
  `/etc/ssh/sshd_config.d/10-google-authenticator.conf` sets
  `KbdInteractiveAuthentication yes` and `UsePAM yes`, is checked with
  `sshd -t`, and is removed again if invalid. The `10-` prefix makes it sort
  before most vendor drop-ins (sshd keeps the first value it reads, in
  lexical order); a lower-numbered file such as `00-*.conf` would still win.
  sshd only reads the new file on reload: `sudo systemctl reload ssh`.

Key-only logins skip PAM, so the code is never asked for them.
`AuthenticationMethods` is deliberately not set by the installer. To require
key plus code on a key-only host, add this yourself (a manual owner
decision, and enroll first):

```text
AuthenticationMethods publickey,keyboard-interactive
KbdInteractiveAuthentication yes
UsePAM yes
```

After you enroll, anything that calls `sudo` without a terminal (cron, CI,
`sudo -n`) stops working for that account: the code prompt cannot be answered.
Run unattended jobs as root or from a user that is not enrolled.

## Enroll

```bash
google-authenticator
```

- Put the scratch codes in your password manager.
- `~/.google_authenticator` holds the TOTP secret and scratch codes. It must
  never enter any sync or backup path (it is not on the ai-state whitelist).

## Avoid lockout

Keep a root shell (`sudo -s`) open in another terminal while testing the first
login, sudo and ssh.

If locked out: boot recovery mode (the root shell there does not use PAM, so
no code is asked), remount the filesystem writable, then disable the profile:

```bash
mount -o remount,rw /
pam-auth-update --disable google-authenticator
```

Never `apt remove libpam-google-authenticator` while the profile is enabled:
`common-auth` would then name a missing module and every `sudo`/login fails.
Run `uninstall_google_authenticator` first.

## Disable

`uninstall_google_authenticator` runs the same `pam-auth-update --disable`
and removes the ssh drop-in and the profile file:

```bash
bash -c 'source distro_config/install_lib/_common.sh; source distro_config/install_lib/system_utils.sh; uninstall_google_authenticator'
```

Preview either function with `DRY_RUN=1`.
