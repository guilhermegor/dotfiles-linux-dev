#!/usr/bin/env bats
#
# claudestatus top-bar logo (#753): both SVGs are well-formed XML and the extension
# uses the bundled symbolic icon instead of the stock system-monitor one.

ICONS="ai_clients/claude/claudestatus_bar/gnome-extension/icons"
EXT="ai_clients/claude/claudestatus_bar/gnome-extension/extension.js"

setup() {
    cd "$BATS_TEST_DIRNAME/.."
}

@test "logo SVGs parse as XML" {
    for f in token-budget.svg token-budget-symbolic.svg; do
        run python3 -c 'import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$ICONS/$f"
        [ "$status" -eq 0 ]
    done
}

@test "symbolic icon is monochrome black" {
    run grep -Eoi '#[0-9a-f]{3,6}' "$ICONS/token-budget-symbolic.svg"
    [ "$status" -eq 0 ]
    [ -z "$(printf '%s\n' "$output" | grep -vi '^#000000$')" ]
}

@test "extension.js uses the bundled symbolic icon" {
    run grep -E 'new Indicator\(HELPER_DIR, .*icons/token-budget-symbolic\.svg' "$EXT"
    [ "$status" -eq 0 ]
    run grep -c 'utilities-system-monitor-symbolic' "$EXT"
    [ "$output" = "0" ]
}

@test "symbolic icon sits on the pixel grid (#803)" {
    run python3 - "$ICONS/token-budget-symbolic.svg" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
bad = [w for w in re.findall(r'stroke-width="([^"]+)"', text) if w != "1"]
text = re.sub(r"#[0-9a-fA-F]{3,6}\b|<\?.*?\?>|(?:opacity|version)=\"[^\"]*\"", "", text)
bad += [n for n in re.findall(r"-?\d*\.\d+", text) if not re.fullmatch(r"-?\d*\.5", n)]
if bad:
    sys.exit("off-grid values: " + " ".join(bad))
PY
    [ "$status" -eq 0 ]
}

@test "extension.js hands the icon path to the St.Icon gicon" {
    run grep -E 'new St\.Icon\(\{gicon: Gio\.icon_new_for_string\(iconPath\)' "$EXT"
    [ "$status" -eq 0 ]
}
