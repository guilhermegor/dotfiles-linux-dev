#!/bin/bash
# Keep MEMORY.md hook text in sync with memory-file frontmatter (#956).
#
# An index entry is "- [<title>](<file>) — <hook>". The HOOK must equal the file's
# `description:`; the TITLE is the author's and is never compared or rewritten (live titles are
# human phrases, frontmatter `name:` is a kebab slug, so they legitimately differ). A hand-written
# hook can outlive an amended rule (filings-cvm, 2026-11-07: "NEVER resolve" outlived "resolve
# once settled"); when a memory lifts or amends a rule, say so in its `description:`.
#
# Sourced by memory_index_drift.sh. By hand: source this file; memory_index_sync <memory-dir>

_MEMORY_ENTRY_RE='^- \[([^]]*)\]\(([^)]*)\) — (.*)$'
_MEMORY_FILE_RE='^[A-Za-z0-9][A-Za-z0-9._-]*\.md$'

# memory_fm_field FILE KEY — first frontmatter value for KEY, quotes and CR stripped.
memory_fm_field() {
    awk -v key="$2" '
        { sub(/\r$/, "") }
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { exit }
        index($0, key ":") == 1 {
            v = substr($0, length(key) + 2)
            sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
            if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
            print v; exit
        }' "$1"
}

# memory_index_sync DIR — rewrite DIR/MEMORY.md in place: keep every non-entry line (header,
# blanks) and every existing title, set each hook to the file's description, drop entries whose
# file is gone, append unindexed files (title = name). Files lacking name or description are
# skipped and listed on stderr.
memory_index_sync() {
    local dir=$1 index="$1/MEMORY.md" tmp line f base desc name title seen=" "
    tmp=$(mktemp) || return 1
    if [[ -f "$index" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line=${line%$'\r'}
            if [[ "$line" =~ $_MEMORY_ENTRY_RE ]]; then
                title=${BASH_REMATCH[1]}
                base=${BASH_REMATCH[2]}
                [[ "$base" =~ $_MEMORY_FILE_RE && -f "$dir/$base" ]] || continue
                desc=$(memory_fm_field "$dir/$base" description)
                if [[ -z "$desc" ]]; then printf '%s\n' "$line" >> "$tmp"; else
                    printf -- '- [%s](%s) — %s\n' "$title" "$base" "$desc" >> "$tmp"; fi
                seen+="$base "
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$index"
    fi
    for f in "$dir"/*.md; do
        base=$(basename "$f")
        [[ -f "$f" && "$base" != MEMORY.md && "$seen" != *" $base "* ]] || continue
        name=$(memory_fm_field "$f" name)
        desc=$(memory_fm_field "$f" description)
        if [[ -z "$name" || -z "$desc" ]]; then echo "skipped (no name/description): $base" >&2; continue; fi
        printf -- '- [%s](%s) — %s\n' "$name" "$base" "$desc" >> "$tmp"
    done
    mv -- "$tmp" "$index"
}

# memory_index_drift DIR — one line per drifted entry, names and kinds only:
#   <file>: changed | <file>: missing file | <file>: unindexed | N entries with an invalid link target
# Link text is untrusted, so a file name is echoed only if it matches the allowlist. Never fails.
memory_index_drift() {
    local dir=$1 index="$1/MEMORY.md" line base want have f invalid=0 seen=" "
    [[ -f "$index" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        [[ "$line" =~ $_MEMORY_ENTRY_RE ]] || continue
        base=${BASH_REMATCH[2]}
        have=${BASH_REMATCH[3]}
        if [[ ! "$base" =~ $_MEMORY_FILE_RE ]]; then invalid=$((invalid + 1)); continue; fi
        seen+="$base "
        if [[ ! -f "$dir/$base" ]]; then echo "$base: missing file"; continue; fi
        want=$(memory_fm_field "$dir/$base" description)
        [[ -z "$want" || "$have" == "$want" ]] || echo "$base: changed"
    done < "$index"
    for f in "$dir"/*.md; do
        base=$(basename "$f")
        [[ -f "$f" && "$base" != MEMORY.md && "$seen" != *" $base "* ]] || continue
        [[ -n "$(memory_fm_field "$f" description)" ]] && echo "$base: unindexed"
    done
    [[ $invalid -eq 0 ]] || echo "$invalid entries with an invalid link target"
    return 0
}
