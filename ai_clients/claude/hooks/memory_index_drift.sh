#!/bin/bash
# PostToolUse (Write|Edit) hook: after a write under a */memory/ directory, report any
# MEMORY.md index line that no longer matches its file's frontmatter (#956).
#
# Advisory only: speaks through additionalContext JSON, always exits 0, fails open on a
# missing jq or an unparseable payload. The fix is to regenerate the index:
#   source ~/.claude/hooks/lib/memory_index.sh
#   memory_index_generate <memory-dir> > <memory-dir>/MEMORY.md

command -v jq >/dev/null 2>&1 || exit 0

path=$(jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[[ "$path" == */memory/*.md ]] || exit 0

dir=$(dirname "$path")
# shellcheck source=lib/memory_index.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/memory_index.sh"

drift=$(memory_index_drift "$dir")
[[ -n "$drift" ]] || exit 0

jq -n --arg d "$drift" --arg dir "$dir" '{
    hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: ("MEMORY.md DRIFT in \($dir) — the index is always loaded, so a stale line outranks the file body. Regenerate it from frontmatter (source ~/.claude/hooks/lib/memory_index.sh; memory_index_generate DIR > DIR/MEMORY.md); if a rule was lifted or amended, say so in that memory'"'"'s description first.\n" + $d)
    }
}'
exit 0
