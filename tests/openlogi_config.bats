#!/usr/bin/env bats
#
# The tracked openlogi config must carry a top-level schema_version: OpenLogi
# >=0.8 deserializes it as a required field and refuses to start without it (#781).
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    CONFIG="$REPO_ROOT/distro_config/dotfiles/openlogi/config.toml"
}

@test "tracked openlogi config has a top-level schema_version" {
    grep -Eq '^schema_version[[:space:]]*=[[:space:]]*[0-9]+' "$CONFIG"
}
