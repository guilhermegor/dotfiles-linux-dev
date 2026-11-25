#!/bin/bash
# Shared parser for the AI-state include list (dotfiles-linux-dev#1126), sourced by
# ai_state_sync.sh (to widen the whitelist) and lib/prune.sh (to never offer an included
# artifact for removal). One parser, so the two can never disagree on what a line means.
#
# The list is <claude dir>/ai-state-sync.include: one path per line, relative to the
# claude dir, `#` comments and blank lines ignored. It lives in the (private) work tree, so
# the public repo never names what is in it. A missing or unreadable file is an empty list.
#
# A line is rejected (reported on stderr, never fatal) when it starts with `!`, contains
# `..`, or lives under /projects/ (already synced by the fixed whitelist).

# Echoes each valid line normalised to a leading "/", one per line.
ai_state_include_paths() {
    local file="$1" line
    [[ -r "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == '!'* || "$line" == *..* || "$line" == /projects/* || "$line" == projects/* ]]; then
            printf '[ai-state-sync] ignoring include line: %s\n' "$line" >&2
            continue
        fi
        [[ "$line" == /* ]] || line="/$line"
        printf '%s\n' "$line"
    done <"$file"
}

# A listed path is literal, so the gitignore pattern characters in it are escaped.
_ai_state_glob_escape() {
    local s="$1" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        [[ "$c" == [][*?\\] ]] && out+='\'
        out+="$c"
    done
    printf '%s' "$out"
}

# Echoes each path the whitelist text re-includes whole: a glob-free `!X` line that no later
# ignore line narrows again (`!/projects/` is followed by `/projects/*`, so it is not whole).
_ai_state_whitelisted_paths() {
    local -a lines=()
    local i j x
    mapfile -t lines <<<"$1"
    for i in "${!lines[@]}"; do
        [[ "${lines[i]}" == '!/'* && "${lines[i]}" != *[][*?\\]* ]] || continue
        x="${lines[i]#!}"
        x="${x%/}"
        for ((j = i + 1; j < ${#lines[@]}; j++)); do
            [[ "${lines[j]}" != '!'* && "${lines[j]}" == "$x/"* ]] && continue 2
        done
        printf '%s\n' "$x"
    done
}

# Echoes gitignore lines re-including every listed path. With `/*` ignored, git needs each
# ancestor re-included then its children re-ignored: /a/b/ => !/a/ /a/* !/a/b/. Ancestor
# lines are emitted once (a repeated `/a/*` would re-ignore an earlier include), and a path
# nested under another listed path is dropped as already covered. The optional second
# argument is the fixed whitelist: a path inside a directory it already re-includes whole
# emits nothing, since `/memory/*` would re-ignore every unlisted file there.
ai_state_include_excludes() {
    local -a paths=() whole=()
    local p q w prefix comp rest last dir
    local -A seen=()
    mapfile -t paths < <(ai_state_include_paths "$1")
    mapfile -t whole < <(_ai_state_whitelisted_paths "${2:-}")
    for p in "${paths[@]}"; do
        for w in "${whole[@]}"; do
            [[ -n "$w" && ("${p%/}" == "$w" || "${p%/}" == "$w"/*) ]] && continue 2
        done
        for q in "${paths[@]}"; do
            [[ "${p%/}" != "${q%/}" && "${p%/}/" == "${q%/}/"* ]] && continue 2
        done
        prefix=""
        rest="${p#/}"
        while [[ -n "$rest" ]]; do
            comp="$(_ai_state_glob_escape "${rest%%/*}")"
            [[ "$rest" == */* ]] && rest="${rest#*/}" || rest=""
            last=0
            [[ -z "$rest" ]] && last=1
            dir="$prefix/$comp"
            if (( last )); then
                [[ "$p" == */ ]] && dir="$dir/"
                [[ -n "${seen[!$dir]:-}" ]] || printf '!%s\n' "$dir"
                seen["!$dir"]=1
            else
                if [[ -z "${seen[!$dir/]:-}" ]]; then
                    printf '!%s/\n/%s/*\n' "$dir" "${dir#/}"
                    seen["!$dir/"]=1
                fi
            fi
            prefix="$dir"
        done
    done
}

# Succeeds when <relpath> (e.g. skills/foo, hooks/x.sh) equals, sits under, or contains a
# listed path. "Contains" matters: an include of /skills/foo/SKILL.md must still protect
# the skills/foo directory from prune.
ai_state_include_covers() {
    local file="$1" rel="/${2#/}" p
    rel="${rel%/}"
    while IFS= read -r p; do
        p="${p%/}"
        [[ "$rel" == "$p" || "$rel" == "$p"/* || "$p" == "$rel"/* ]] && return 0
    done < <(ai_state_include_paths "$file" 2>/dev/null)
    return 1
}
