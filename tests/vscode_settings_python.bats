#!/usr/bin/env bats
#
# dotfiles-linux-dev#461: .vscode/settings.json's [python] block declared
# "editor.tabSize": 4 but not "editor.insertSpaces" -- with
# "editor.detectIndentation" left at its VS Code default of true, VS Code
# overrides tabSize/insertSpaces from whatever the opened file already uses,
# so a tab-indented file never converts to the declared 4-space PEP 8 style.
# This asserts both keys are present with the values that make the
# declaration win over file content.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SETTINGS="$REPO_ROOT/.vscode/settings.json"
}

# .vscode/settings.json is JSONC (comments + trailing commas), which jq
# cannot parse directly. Strip both before handing it to jq -- same
# approach as strip_jsonc() in code_editors/vscode.sh.
python_block() {
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
' "$SETTINGS" | jq '.["[python]"]'
}

python_field() {
    python_block | jq -r ".\"$1\""
}

@test ".vscode/settings.json has a [python] block" {
    run python_block
    [ "$status" -eq 0 ]
    [ "$output" != "null" ]
}

@test "[python] editor.tabSize is 4 (PEP 8)" {
    run python_field "editor.tabSize"
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

@test "[python] editor.insertSpaces is true" {
    run python_field "editor.insertSpaces"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "[python] editor.detectIndentation is false (else VS Code overrides insertSpaces/tabSize from the opened file)" {
    run python_field "editor.detectIndentation"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}
