#!/bin/bash
# Installs user-level hook scripts into ~/.claude/hooks/.
#
# Source files live in ai_clients/claude/hooks/<name>.sh and are copied verbatim,
# matching the same pattern used for rules, commands, agents, and skills. The
# scripts are referenced from settings.json (e.g. the SessionStart hook).
#
# To add a new hook:
#   1. Create ai_clients/claude/hooks/<name>.sh.
#   2. Add a copy_hook_file "<name>.sh" call inside install_hooks().
#   3. Reference it from settings.json's "hooks" block.

HOOKS_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"

# A verdict cached by a hook is only valid for the logic that computed it. Deploying a new
# version of that hook without clearing its cache lets the OLD verdict keep being replayed
# until its TTL expires (dotfiles-dev#504) — measured: PR #498 fixed open_review_threads_nudge.sh
# at 15:28:34Z, but a verdict cached 40s earlier by the pre-fix logic was still replayable
# afterwards. Keying each cache entry by a hash of its producing script would make this
# automatic, but that key has to live inside the hook that WRITES the cache
# (open_review_threads_nudge.sh) — out of scope here (held by PR #497). Until a second hook
# grows a cache, a short "cache dir -> producing hook" list is simpler than a hashing layer.
HOOK_CACHE_DIRS=(
    "open-threads-nudge"  # written by open_review_threads_nudge.sh
)

invalidate_hook_caches() {
    local name
    for name in "${HOOK_CACHE_DIRS[@]}"; do
        if [[ -d "$CLAUDE_DIR/$name" ]]; then
            rm -rf "${CLAUDE_DIR:?}/${name:?}"
            print_status "info" "Cleared stale cache: $CLAUDE_DIR/$name"
        fi
    done
}

copy_hook_file() {
    local src="$HOOKS_SRC_DIR/$1"
    local dest="$2/$1"

    if [[ ! -f "$src" ]]; then
        print_status "error" "Hook source not found: $src"
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    chmod +x "$dest"
    print_status "success" "Installed $1 → $dest"
}

install_hooks() {
    print_status "section" "INSTALLING CLAUDE HOOKS"

    local hooks_dir="$CLAUDE_DIR/hooks"
    mkdir -p "$hooks_dir"

    # Every file in hooks/lib/ ships, derived from the directory — never a
    # hand-kept list. The list had gone stale: free_surface.sh and
    # roadmap_unblock.sh were never installed, so the installed
    # subagent_stop_sweep.sh sourced a missing file, gate_free_surface was
    # undefined, and DISPATCH reported "free surface UNKNOWN" every round.
    local lib_file
    for lib_file in "$HOOKS_SRC_DIR"/lib/*; do
        [[ -f "$lib_file" ]] || continue
        copy_hook_file "lib/$(basename "$lib_file")" "$hooks_dir"
    done

    copy_hook_file "session_start_context.sh" "$hooks_dir"
    copy_hook_file "quota_gap_rescue.sh" "$hooks_dir"
    copy_hook_file "pr_template_guard.sh" "$hooks_dir"
    copy_hook_file "issue_template_guard.sh" "$hooks_dir"
    copy_hook_file "commit_title_length_guard.sh" "$hooks_dir"
    copy_hook_file "commit_body_wrap.sh" "$hooks_dir"
    copy_hook_file "commit_secret_guard.sh" "$hooks_dir"
    copy_hook_file "protected_branch_guard.sh" "$hooks_dir"
    copy_hook_file "branch_requires_issue_guard.sh" "$hooks_dir"
    copy_hook_file "release_dispatch_guard.sh" "$hooks_dir"
    copy_hook_file "destructive_command_guard.sh" "$hooks_dir"
    copy_hook_file "push_pr_head_guard.sh" "$hooks_dir"
    copy_hook_file "kanban_lifecycle.sh" "$hooks_dir"
    copy_hook_file "claude_artifact_source_guard.sh" "$hooks_dir"
    copy_hook_file "lesson_capture_checkpoint.sh" "$hooks_dir"
    copy_hook_file "release_due_nudge.sh" "$hooks_dir"
    copy_hook_file "session_capture_audit.sh" "$hooks_dir"
    copy_hook_file "pr_merge_threads_guard.sh" "$hooks_dir"
    copy_hook_file "open_review_threads_nudge.sh" "$hooks_dir"
    copy_hook_file "gh_prose_language_guard.sh" "$hooks_dir"
    copy_hook_file "subagent_stop_sweep.sh" "$hooks_dir"
    copy_hook_file "uncommitted_worktree_guard.sh" "$hooks_dir"
    copy_hook_file "dispatch_free_surface_guard.sh" "$hooks_dir"
    copy_hook_file "round_dispatch_guard.sh" "$hooks_dir"
    copy_hook_file "pr_self_assign.sh" "$hooks_dir"
    copy_hook_file "rtk_worktree_passthrough.sh" "$hooks_dir"
    copy_hook_file "stale_local_ref_guard.sh" "$hooks_dir"

    invalidate_hook_caches
}
