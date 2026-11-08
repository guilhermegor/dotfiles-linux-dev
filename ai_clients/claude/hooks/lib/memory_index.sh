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
#
# File names are untrusted text. Only names matching _MEMORY_FILE_RE are ever echoed or written;
# everything else is counted, and sync and drift apply the same rule so they cannot disagree.

_MEMORY_ENTRY_RE='^- \[([^]]*)\]\(([^)]*)\) — (.*)$'
_MEMORY_FILE_RE='^[A-Za-z0-9][A-Za-z0-9._-]*\.md$'

# memory_fm_field FILE KEY — first frontmatter value for KEY, quotes and CR stripped. Empty when
# the frontmatter is unclosed or the value is a YAML block scalar (> or |), which this
# single-line parser cannot read.
memory_fm_field() {
    awk -v key="$2" '
        { sub(/\r$/, "") }
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { closed = 1; exit }
        !found && NR > 1 && index($0, key ":") == 1 {
            v = substr($0, length(key) + 2)
            sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
            if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
            if (v ~ /^[>|][-+]?$/) v = ""
            out = v; found = 1
        }
        END { if (closed) print out }' "$1"
}

# _memory_link_target LINE — the link target of a bullet line in any shape (`-`/`*` bullet, any
# dash, a `]` in the title), or nothing. Only used to decide "is this file already listed".
_memory_link_target() {
    local line=$1 rest
    [[ "$line" =~ ^[-*][[:space:]]+\[ && "$line" == *"]("* ]] || return 0
    rest=${line#*](}
    printf '%s' "${rest%%)*}"
}

# memory_index_sync DIR — rewrite DIR/MEMORY.md in place (mode and symlink kept): keep every
# non-entry line, every title and every entry it cannot parse; set each parsed entry's hook to
# the file's description; drop entries whose valid-named file is gone; append unindexed files
# (title = name). Files it will not index are listed on stderr.
memory_index_sync() {
    local dir=$1 index tmp line f base desc name title target seen=" "
    index=$(readlink -f -- "$1/MEMORY.md") || return 1
    tmp=$(mktemp "$(dirname "$index")/.MEMORY.md.XXXXXX") || return 1
    if [[ -f "$index" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line=${line%$'\r'}
            if [[ "$line" =~ $_MEMORY_ENTRY_RE ]]; then
                title=${BASH_REMATCH[1]}
                base=${BASH_REMATCH[2]}
                if [[ "$base" =~ $_MEMORY_FILE_RE ]]; then
                    [[ -f "$dir/$base" ]] || continue
                    seen+="$base "
                    desc=$(memory_fm_field "$dir/$base" description)
                    [[ -n "$desc" ]] && line="- [$title]($base) — $desc"
                else
                    echo "kept verbatim (invalid link target): $base" >&2
                fi
            else
                target=$(_memory_link_target "$line")
                [[ "$target" =~ $_MEMORY_FILE_RE ]] && seen+="$target "
            fi
            printf '%s\n' "$line" >> "$tmp"
        done < "$index"
    fi
    for f in "$dir"/*.md; do
        base=$(basename "$f")
        [[ -f "$f" && "$base" != MEMORY.md && "$seen" != *" $base "* ]] || continue
        if [[ ! "$base" =~ $_MEMORY_FILE_RE ]]; then echo "skipped (invalid file name): $base" >&2; continue; fi
        name=$(memory_fm_field "$f" name)
        desc=$(memory_fm_field "$f" description)
        if [[ -z "$name" || -z "$desc" ]]; then echo "skipped (no name/description): $base" >&2; continue; fi
        printf -- '- [%s](%s) — %s\n' "$name" "$base" "$desc" >> "$tmp"
    done
    [[ -f "$index" ]] && chmod --reference="$index" "$tmp" 2>/dev/null
    mv -- "$tmp" "$index" || { rm -f -- "$tmp"; return 1; }
}

# memory_index_drift DIR — one line per drifted entry, names and kinds only:
#   <file>: changed | <file>: missing file | <file>: unindexed | N ... counts
# MEMORY_INDEX_JUST_WROTE=<file> suppresses "unindexed" for that one file. Never fails.
memory_index_drift() {
    local dir=$1 index="$1/MEMORY.md" line base want have f target invalid=0 oddfiles=0 seen=" "
    [[ -f "$index" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        if [[ "$line" =~ $_MEMORY_ENTRY_RE ]]; then
            base=${BASH_REMATCH[2]}
            have=${BASH_REMATCH[3]}
            if [[ ! "$base" =~ $_MEMORY_FILE_RE ]]; then invalid=$((invalid + 1)); continue; fi
            seen+="$base "
            if [[ ! -f "$dir/$base" ]]; then echo "$base: missing file"; continue; fi
            want=$(memory_fm_field "$dir/$base" description)
            [[ -z "$want" || "$have" == "$want" ]] || echo "$base: changed"
        else
            # Listed in a shape we do not compare: counts as indexed, not as unindexed.
            target=$(_memory_link_target "$line")
            [[ "$target" =~ $_MEMORY_FILE_RE ]] && seen+="$target "
        fi
    done < "$index"
    for f in "$dir"/*.md; do
        base=$(basename "$f")
        [[ -f "$f" && "$base" != MEMORY.md && "$seen" != *" $base "* ]] || continue
        if [[ ! "$base" =~ $_MEMORY_FILE_RE ]]; then oddfiles=$((oddfiles + 1)); continue; fi
        [[ "$base" == "${MEMORY_INDEX_JUST_WROTE:-}" ]] && continue
        [[ -n "$(memory_fm_field "$f" description)" ]] && echo "$base: unindexed"
    done
    [[ $invalid -eq 0 ]] || echo "$invalid entries with an invalid link target"
    [[ $oddfiles -eq 0 ]] || echo "$oddfiles files with a non-conforming name"
    return 0
}
