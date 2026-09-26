#!/usr/bin/env bats
#
# Unit tests for the permissions.deny additions in ai_clients/claude/settings.json
# (dotfiles-dev#503): secret-bearing paths and environment-dumping Bash commands
# the deny list previously missed.
#
# Three proposed entries from the issue were deliberately NOT adopted and must
# never reappear:
#   - Read(**/.env.*)   would re-collapse the enumerated .env suffix list back
#     into the glob it replaced (dotfiles-dev#123/#124), denying .env.example/
#     .env.sample/.env.template again. Covered in depth by settings_env_deny.bats;
#     re-asserted here as a second line of defence since this file is the one
#     that reviews this issue's diff.
#   - Bash(cat .env*)   same .env.example problem, plus cwd-relative.
#   - Bash(echo $*)     `deny` cannot be approved past, and this would block the
#     AGENTS.md-mandated `echo "===EXIT=$?==="` git-write verification step.
#
# `Bash(printenv*)` (bare, no space/colon) was in the issue's proposed list but
# does not match this repo's `<cmd>:*` convention (see `Bash(rm -rf /:*)`, and
# the pre-existing ask-list entry `Bash(printenv:*)`); per the Claude Code docs,
# a trailing `*` with no separator is a raw string-suffix match, not the
# documented `:*`/` *` "command plus any args" form used everywhere else in
# this file. `Bash(printenv:*)` is the form actually adopted.
#
# Run locally: bats tests/   (install with: sudo apt-get install -y bats)

setup() {
    SETTINGS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/settings.json"
}

@test "settings.json is valid JSON" {
    run jq empty "$SETTINGS"
    [ "$status" -eq 0 ]
}

# --- the ten adopted entries -----------------------------------------------

@test "deny list contains Read(**/secrets/**)" {
    run jq -e '.permissions.deny | index("Read(**/secrets/**)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "deny list contains Read(**/credentials/**)" {
    run jq -e '.permissions.deny | index("Read(**/credentials/**)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "deny list keeps the narrower Read(**/.aws/credentials) alongside the broader glob" {
    run jq -e '.permissions.deny | index("Read(**/.aws/credentials)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "deny list contains Read(**/config/credentials.*)" {
    run jq -e '.permissions.deny | index("Read(**/config/credentials.*)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "deny list contains Read(**/*.key)" {
    run jq -e '.permissions.deny | index("Read(**/*.key)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "deny list contains Read(**/*.p12)" {
    run jq -e '.permissions.deny | index("Read(**/*.p12)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "deny list contains Read(**/*.pfx)" {
    run jq -e '.permissions.deny | index("Read(**/*.pfx)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "deny list contains Bash(cat ~/.ssh/*)" {
    run jq -e '.permissions.deny | index("Bash(cat ~/.ssh/*)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "deny list contains Bash(printenv:*), the cmd:* convention form" {
    run jq -e '.permissions.deny | index("Bash(printenv:*)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "deny list does NOT contain the bare-star Bash(printenv*) form" {
    run jq -e '.permissions.deny | index("Bash(printenv*)")' "$SETTINGS"
    [ "$status" -ne 0 ]
}

@test "deny list contains Bash(env:*)" {
    run jq -e '.permissions.deny | index("Bash(env:*)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

# Bash(env) is an EXACT-command rule: it denies a bare `env` and nothing else, so
# `env | grep -i token` walks straight past it. The prefix form above is the only
# one that closes that, and it also still matches the bare `env`.
@test "deny list does NOT contain the exact-match Bash(env) form" {
    run jq -e '.permissions.deny | index("Bash(env)")' "$SETTINGS"
    [ "$status" -ne 0 ]
}

@test "the ask list spells env the same way the deny list does" {
    run jq -e '.permissions.ask | index("Bash(env:*)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "deny list contains Bash(cat /proc/*/environ)" {
    run jq -e '.permissions.deny | index("Bash(cat /proc/*/environ)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

# --- the three refused entries must never land ------------------------------

@test "deny list does NOT contain the collapsed Read(**/.env.*) glob" {
    run jq -e '.permissions.deny | index("Read(**/.env.*)")' "$SETTINGS"
    [ "$status" -ne 0 ]
}

@test "deny list does NOT contain the cwd-relative Bash(cat .env*)" {
    run jq -e '.permissions.deny | index("Bash(cat .env*)")' "$SETTINGS"
    [ "$status" -ne 0 ]
}

@test "deny list does NOT contain Bash(echo \$*), which would block the git-write EXIT check" {
    run jq -e '.permissions.deny | index("Bash(echo $*)")' "$SETTINGS"
    [ "$status" -ne 0 ]
}

# --- the .env enumeration must stay enumerated (dotfiles-dev#123/#124) ------

@test "the .env enumeration still has all eight environment-suffix entries" {
    run jq -r '[.permissions.deny[] | select(startswith("Read(**/.env.") and (. != "Read(**/.env.local)") and (. != "Read(**/.env.*.local)"))] | length' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "$output" -eq 8 ]
}
