#!/bin/bash
# Derive MEMORY.md index lines from memory-file frontmatter and report drift (#956).
#
# A MEMORY.md line is "- [<name>](<file>) — <description>", generated from the file's own
# frontmatter, never hand-edited. A hand-written hook text can keep stating a rule the body has
# since amended (filings-cvm, 2026-11-07: "NEVER resolve" outlived "resolve once settled").
# When a memory lifts or amends a rule, say so in its `description:`; the generator carries it.
#
# Sourced by memory_index_drift.sh. Also usable by hand:
#   source memory_index.sh && memory_index_generate <memory-dir> > <memory-dir>/MEMORY.md

# memory_fm_field FILE KEY — first frontmatter value for KEY, quotes stripped.
memory_fm_field() {
    awk -v key="$2" '
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { exit }
        index($0, key ":") == 1 {
            v = substr($0, length(key) + 2)
            sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
            if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
            print v; exit
        }' "$1"
}

# memory_index_line FILE — the canonical index line; empty when name or description is missing.
memory_index_line() {
    local name desc
    name=$(memory_fm_field "$1" name)
    desc=$(memory_fm_field "$1" description)
    [[ -n "$name" && -n "$desc" ]] || return 0
    printf -- '- [%s](%s) — %s\n' "$name" "$(basename "$1")" "$desc"
}

# memory_index_generate DIR — canonical index for every memory file in DIR (MEMORY.md excluded).
memory_index_generate() {
    local f
    for f in "$1"/*.md; do
        [[ -f "$f" && "$(basename "$f")" != MEMORY.md ]] || continue
        memory_index_line "$f"
    done
}

# memory_index_drift DIR — one line per index entry whose text differs from its file's
# canonical line (or whose file is gone), and one per memory file with no index entry.
# Prints nothing when in sync. Never fails.
memory_index_drift() {
    local dir=$1 index="$1/MEMORY.md" line file want f
    local entry_re='^- \[[^]]*\]\(([^)]+\.md)\)'
    [[ -f "$index" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ $entry_re ]] || continue
        file=${BASH_REMATCH[1]}
        # A link target is untrusted text: never leave DIR, never echo a path-shaped name.
        [[ "$file" == */* || "$file" == *..* ]] && continue
        if [[ ! -f "$dir/$file" ]]; then
            echo "$file: missing file"
            continue
        fi
        want=$(memory_index_line "$dir/$file")
        [[ -z "$want" ]] && continue
        [[ "$line" == "$want" ]] || echo "$file: changed"
    done < "$index"
    for f in "$dir"/*.md; do
        [[ -f "$f" && "$(basename "$f")" != MEMORY.md ]] || continue
        [[ -n "$(memory_index_line "$f")" ]] || continue
        grep -qF "]($(basename "$f"))" "$index" || echo "$(basename "$f"): unindexed"
    done
}
