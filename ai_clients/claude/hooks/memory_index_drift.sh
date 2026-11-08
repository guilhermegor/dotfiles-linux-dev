#!/bin/bash
# PostToolUse (Write|Edit) hook: after a write under a */memory/ directory, report any
# MEMORY.md index line that no longer matches its file's frontmatter (#956).
#
# Advisory only: speaks through additionalContext JSON, always exits 0, fails open on a
# missing jq or an unparseable payload. The fix is memory_index_sync <memory-dir> (lib/).

command -v jq >/dev/null 2>&1 || exit 0

path=$(jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[[ "$path" == */memory/*.md ]] || exit 0

# Only real auto-memory stores: <config>/projects/*/memory/. Anything else (a repo's own
# memory/ folder, a symlink out) is untrusted text and stays silent.
path=$(realpath -m -- "$path" 2>/dev/null) || exit 0
root=$(realpath -m -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" 2>/dev/null) || exit 0
rel=${path#"$root"/}
[[ "$path" != "$rel" && "$rel" =~ ^[^/]+/memory/[^/]+\.md$ ]] || exit 0

dir=$(dirname "$path")
hooks_dir=$(dirname "$(realpath -- "${BASH_SOURCE[0]}")")
# shellcheck source=lib/memory_index.sh
source "$hooks_dir/lib/memory_index.sh" 2>/dev/null || exit 0

# The normal workflow writes the memory file first and its MEMORY.md pointer second, so the
# file just written is not yet "unindexed" in any useful sense.
drift=$(MEMORY_INDEX_JUST_WROTE=$(basename "$path") memory_index_drift "$dir")
# Nag only for what memory_index_sync can repair; the "N ..." count lines need a hand fix and
# would otherwise re-fire on every memory write forever.
grep -Eq ': (changed|missing file|unindexed)$' <<< "$drift" || exit 0

script=$(printf 'source %q; memory_index_sync %q' "$hooks_dir/lib/memory_index.sh" "$dir")
fix=$(printf 'bash -c %q' "$script")

jq -n --arg d "$drift" --arg dir "$dir" --arg fix "$fix" '{
    hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: ("MEMORY.md DRIFT in \($dir) (file names and kinds only; read the files yourself) — the index is always loaded, so a stale line outranks the file body. Sync hook text from frontmatter (keeps titles and header): \($fix) . If a rule was lifted or amended, say so in that memory'"'"'s description first.\n" + $d)
    }
}'
exit 0
