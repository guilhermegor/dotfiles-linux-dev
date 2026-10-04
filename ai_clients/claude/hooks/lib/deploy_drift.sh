#!/bin/bash
# Detects drift between ai_clients/claude/** (source) and ~/.claude/** (live) — sourced by
# session_start_context.sh so a stale deploy is visible at session start (dotfiles-linux-dev#345).
#
# Why not `diff -rq` the two trees: skills transform on install (flat source
# `skills/<name>.md` -> nested live `skills/<name>/SKILL.md`, ai_clients/claude/lib/skills.sh),
# so a naive recursive diff reports the entire skills subtree as divergent. Every transform
# below is read out of the installer that performs it, not guessed:
#
#   commands: commands/<name>.md  -> commands/<name>.md        globbed,  lib/slash_commands.sh
#   agents:   agents/<name>.md    -> agents/<name>.md          globbed,  lib/agents.sh
#   skills:   skills/<name>.md    -> skills/<name>/SKILL.md    globbed,  lib/skills.sh (nested)
#   rules:    rules/<name>        -> rules/<name>              enumerated via copy_rule_file, lib/rules.sh
#   hooks:    hooks/<name>        -> hooks/<name>              enumerated via copy_hook_file, lib/hooks.sh
#                                                               (name may carry a "lib/" prefix,
#                                                               preserved verbatim into the dest path)
#
# Two kinds of drift are counted, not just one: files present both places with different
# content, AND files present in source but never copied live at all. A detector that only
# diffs existing pairs misses exactly what #345 found (rules/web.md, 4 skills, never deployed).

set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "deploy_drift.sh is meant to be sourced, not executed." >&2
    exit 1
fi

# Names passed to copy_rule_file()/copy_hook_file() calls in a lib script, one per line.
# Comment lines are stripped first — both lib files document the convention with a literal
# example call in a header comment, which an unfiltered grep would count as a real call.
_deploy_drift_copy_names() {
    local lib_file="$1" fn_name="$2"
    grep -v '^[[:space:]]*#' "$lib_file" 2>/dev/null \
        | grep -oE "${fn_name}[[:space:]]+\"[^\"]+\"" \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        | sort -u
}

# Echoes "<abs_source_path>\t<dest_relpath_under_claude_dir>" for every artifact the installer
# would copy into ~/.claude, one per line.
_deploy_drift_manifest() {
    local claude_src="$1" f name

    for f in "$claude_src"/commands/*.md; do
        [[ -e "$f" ]] || continue
        printf '%s\tcommands/%s\n' "$f" "$(basename "$f")"
    done

    for f in "$claude_src"/agents/*.md; do
        [[ -e "$f" ]] || continue
        printf '%s\tagents/%s\n' "$f" "$(basename "$f")"
    done

    for f in "$claude_src"/skills/*.md; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f" .md)"
        printf '%s\tskills/%s/SKILL.md\n' "$f" "$name"
    done

    while IFS= read -r name; do
        [[ -n "$name" && -f "$claude_src/rules/$name" ]] || continue
        printf '%s\trules/%s\n' "$claude_src/rules/$name" "$name"
    done < <(_deploy_drift_copy_names "$claude_src/lib/rules.sh" "copy_rule_file")

    while IFS= read -r name; do
        [[ -n "$name" && -f "$claude_src/hooks/$name" ]] || continue
        printf '%s\thooks/%s\n' "$claude_src/hooks/$name" "$name"
    done < <(_deploy_drift_copy_names "$claude_src/lib/hooks.sh" "copy_hook_file")
}

# Prints "<divergent_count>\t<never_deployed_count>" for $1 (repo root containing
# ai_clients/claude) against $2 (live ~/.claude dir). A never-deployed file counts as
# divergent too (a missing file is the maximal case of "differs").
deploy_drift_counts() {
    local repo_root="$1" claude_dir="$2"
    local claude_src="$repo_root/ai_clients/claude"
    [[ -d "$claude_src" ]] || { printf '0\t0\n'; return 0; }

    local divergent=0 never=0 src dest_rel dest_abs
    while IFS=$'\t' read -r src dest_rel; do
        [[ -n "$src" ]] || continue
        dest_abs="$claude_dir/$dest_rel"
        if [[ ! -f "$dest_abs" ]]; then
            never=$((never + 1))
            divergent=$((divergent + 1))
        elif ! cmp -s "$src" "$dest_abs"; then
            divergent=$((divergent + 1))
        fi
    done < <(_deploy_drift_manifest "$claude_src")

    printf '%s\t%s\n' "$divergent" "$never"
}

# One-line report; silent when the tree is clean. $1/$2 default to the running session's
# project dir and Claude config dir — overridable for tests.
emit_deploy_drift_status() {
    local repo_root="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
    local claude_dir="${2:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"

    [[ -d "$repo_root/ai_clients/claude" ]] || return 0

    local divergent never
    IFS=$'\t' read -r divergent never <<< "$(deploy_drift_counts "$repo_root" "$claude_dir")"
    [[ "${divergent:-0}" -gt 0 ]] || return 0

    printf '[deploy-drift] %s file(s) in ai_clients/claude/ differ from %s (%s never deployed) — run `make ai_clients` to sync.\n' \
        "$divergent" "$claude_dir" "$never"
}
