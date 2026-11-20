#!/usr/bin/env bats
#
# refresh_apt_keyring (distro_config/install_lib/_common.sh): compare-and-replace for third-party
# apt signing keys (#352, #353). curl, gpg and sudo are stubbed; no network, no root.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    export LOG_FILE="$TMP/log" KEYRING="$TMP/keyring.gpg" SUDO_LOG="$TMP/sudo"
    mkdir -p "$TMP/bin"
    # curl stub: writes $PUBLISHED to the -o target, or fails when CURL_FAIL=1.
    cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
[ "${CURL_FAIL:-0}" = 1 ] && exit 22
while [ $# -gt 0 ]; do [ "$1" = -o ] && printf '%s' "$PUBLISHED" > "$2"; shift; done
STUB
    # gpg stub: `--dearmor -o OUT IN` writes "bin:<IN contents>" to OUT.
    cat > "$TMP/bin/gpg" <<'STUB'
#!/bin/bash
out=""; for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
printf 'bin:%s' "$(cat "${!#}")" > "$out"
STUB
    printf '#!/bin/bash\necho "$*" >> "$SUDO_LOG"\n"$@"\n' > "$TMP/bin/sudo"
    chmod +x "$TMP/bin/curl" "$TMP/bin/gpg" "$TMP/bin/sudo"
    export PATH="$TMP/bin:$PATH"
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
}

teardown() {
    rm -rf "$TMP"
}

@test "an unchanged published key is a no-op" {
    printf 'same' > "$KEYRING"
    PUBLISHED=same run refresh_apt_keyring https://example.test/key "$KEYRING"
    [ "$status" -eq 0 ]
    [ ! -e "$SUDO_LOG" ]
}

@test "a rotated key replaces the installed one" {
    printf 'expired' > "$KEYRING"
    PUBLISHED=rotated run refresh_apt_keyring https://example.test/key "$KEYRING"
    [ "$status" -eq 0 ]
    [ "$(cat "$KEYRING")" = rotated ]
}

@test "--dearmor compares the dearmored form, so an unchanged armored key is still a no-op" {
    printf 'bin:armored' > "$KEYRING"
    PUBLISHED=armored run refresh_apt_keyring https://example.test/key.asc "$KEYRING" --dearmor
    [ "$status" -eq 0 ]
    [ ! -e "$SUDO_LOG" ]
}

@test "a failed download returns 1 and keeps the old key" {
    printf 'expired' > "$KEYRING"
    CURL_FAIL=1 run refresh_apt_keyring https://example.test/key "$KEYRING"
    [ "$status" -eq 1 ]
    [ "$(cat "$KEYRING")" = expired ]
}

# Invariant: an installer that returns early once its tool exists must still refresh its key when
# the tool came from the vendor apt repo — the early return is how the gh key went stale.
@test "every already-installed apt-repo installer refreshes its key" {
    local spec file fn block
    for spec in \
        install_coding_lib/databases.sh:install_postgresql \
        install_coding_lib/containers.sh:install_docker \
        install_coding_lib/containers.sh:install_kubectl \
        install_lib/browsers.sh:install_brave \
        install_coding_lib/languages.sh:install_blueprintx; do
        file="$REPO_ROOT/distro_config/${spec%%:*}"
        fn="${spec##*:}"
        block="$(sed -n "/^${fn}() *{/,/^}/p" "$file" | sed -n '/already installed/,/return 0/p')"
        [[ "$block" == *refresh_apt_keyring* ]] || { echo "missing in $fn"; return 1; }
    done
}

@test "pgAdmin no longer skips the key import when a keyring exists" {
    fn="$(sed -n '/^install_pgadmin() *{/,/^}/p' "$REPO_ROOT/distro_config/install_coding_lib/databases.sh")"
    [[ "$fn" == *refresh_apt_keyring* ]]
    [[ "$fn" != *'skipping key import'* ]]
}
