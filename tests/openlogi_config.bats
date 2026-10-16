#!/usr/bin/env bats
#
# The tracked openlogi config must carry a top-level schema_version: OpenLogi
# >=0.8 deserializes it as a required field and refuses to start without it (#781).
# Parsed with stdlib tomllib so a key nested under a [table] does not pass.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    CONFIG="$REPO_ROOT/distro_config/dotfiles/openlogi/config.toml"
    command -v python3 >/dev/null || skip "python3 not installed"
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' \
        || skip "python3 >= 3.11 required for tomllib"
}

has_top_level_schema_version() {
    python3 -I -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); v=d.get("schema_version"); sys.exit(0 if type(v) is int and v>0 else 1)' "$1"
}

@test "tracked openlogi config has a top-level schema_version" {
    has_top_level_schema_version "$CONFIG"
}

@test "schema_version nested under a [table] is rejected" {
    local f="$BATS_TEST_TMPDIR/nested.toml"
    printf '[devices]\nschema_version = 7\n' > "$f"
    run has_top_level_schema_version "$f"
    [ "$status" -ne 0 ]
}
