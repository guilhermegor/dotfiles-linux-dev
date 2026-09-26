#!/usr/bin/env bats
#
# dotfiles-dev#484: jetmartin.bats was installed by hand (never in
# .vscode/extensions.txt) and .gitlint had no files.associations entry, so
# both were lost on a fresh install. This asserts both are declared, and
# that no "*.bats" association was added alongside the extension -- that
# would override the extension's own contributed "bats" language and force
# every test file back to plain Shell Script highlighting.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    EXTENSIONS="$REPO_ROOT/.vscode/extensions.txt"
    SETTINGS="$REPO_ROOT/.vscode/settings.json"
}

# .vscode/settings.json is JSONC (comments + trailing commas), which jq
# cannot parse directly. Strip both -- same approach as strip_jsonc() in
# code_editors/vscode.sh.
associations_block() {
    python3 -c '
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
out, i, n = [], 0, len(s)
in_str = esc = False
while i < n:
    c = s[i]
    if in_str:
        out.append(c)
        if esc:
            esc = False
        elif c == "\\":
            esc = True
        elif c == "\"":
            in_str = False
        i += 1
        continue
    if c == "\"":
        in_str = True
        out.append(c)
        i += 1
        continue
    if c == "/" and i + 1 < n and s[i + 1] == "/":
        while i < n and s[i] != "\n":
            i += 1
        continue
    if c == "/" and i + 1 < n and s[i + 1] == "*":
        i += 2
        while i + 1 < n and not (s[i] == "*" and s[i + 1] == "/"):
            i += 1
        i += 2
        continue
    out.append(c)
    i += 1
res = re.sub(r",(\s*[}\]])", r"\1", "".join(out))
sys.stdout.write(res)
' "$SETTINGS" | jq '.["files.associations"]'
}

@test "jetmartin.bats is installed via extensions.txt and .gitlint is associated as ini (not *.bats)" {
    grep -qx "vscode:jetmartin.bats" "$EXTENSIONS"

    run associations_block
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.[".gitlint"]')" = "ini" ]
    [ "$(echo "$output" | jq -r 'has("*.bats")')" = "false" ]
}
