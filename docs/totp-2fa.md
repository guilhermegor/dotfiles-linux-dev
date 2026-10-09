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

SSH is conditional. The installer reads the effective config with
`sudo sshd -T` first:

- **Key-only host** (`passwordauthentication no` and
  `kbdinteractiveauthentication no`, the Ubuntu default): the drop-in is
  skipped with a warning, and ssh is left unchanged. Enabling
  keyboard-interactive here would reopen a password login path, and because
  of `nullok` an unenrolled account would get in with the password alone.
  The same happens if the `sshd -T` read fails (fail closed), or if
  openssh-server is not installed.
- **Password logins already on:** the drop-in
  `/etc/ssh/sshd_config.d/10-google-authenticator.conf` sets
  `KbdInteractiveAuthentication yes` and `UsePAM yes`, is checked with
  `sshd -t`, and is removed again if invalid. The `10-` prefix makes it sort
  before most vendor drop-ins (sshd keeps the first value it reads, in
  lexical order); a lower-numbered file such as `00-*.conf` would still win.

Key-only logins skip PAM, so the code is never asked for them.
`AuthenticationMethods` is deliberately not set by the installer. To require
key plus code on a key-only host, add this yourself (a manual owner
decision, and enroll first):

```text
AuthenticationMethods publickey,keyboard-interactive
KbdInteractiveAuthentication yes
UsePAM yes
```

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

If locked out: boot recovery mode, then run

```bash
pam-auth-update --disable google-authenticator
```

## Disable

`uninstall_google_authenticator` runs the same `pam-auth-update --disable`
and removes the ssh drop-in and the profile file:

```bash
bash -c 'source distro_config/install_lib/_common.sh; source distro_config/install_lib/system_utils.sh; uninstall_google_authenticator'
```

Preview either function with `DRY_RUN=1`.
