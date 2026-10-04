#!/usr/bin/env bash
# SessionStart hook — injects cross-project context that Claude Code does NOT
# auto-load (only the current project's memory + the global CLAUDE.md load).
#
# It surfaces, every session:
#   - the rtk-lossy `ls`/`find` caveat (a recurring failure mode), and
#   - where the global scaffolding-lessons backport queue lives;
# and, when the repo is a BlueprintX template repo or a scaffolded project,
#   - the proving-ground project memory + this repo's git-ignored lessons file.
#
# SessionStart adds this script's PLAIN STDOUT to Claude's context (exit 0), so
# the payload is printed with `printf` to stdout — NOT via `print_status` (which
# is for diagnostics on stderr). Kept dependency-free so it runs early and never
# fails the session.
set -uo pipefail

# shellcheck source=lib/deploy_drift.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/deploy_drift.sh"
# shellcheck source=lib/lesson_mirrors.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lesson_mirrors.sh"
# shellcheck source=lib/worktree_fanout.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/worktree_fanout.sh"
# shellcheck source=lib/reviewer_probe.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/reviewer_probe.sh"

emit_cross_project_context() {
	local claude_dir lessons_store proving_mem cwd
	claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
	lessons_store="$claude_dir/memory/lessons"
	proving_mem="$claude_dir/projects/-home-guilhermegor-dev-perfil-mensal-cvm/memory"
	cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

	# Always: the recurring rtk-lossy failure mode.
	printf '%s\n' "[cross-project-context] rtk proxy can collapse real ls/find output to \"(empty)\". NEVER conclude a path is empty/absent from rtk-proxied ls/find — verify with the Read or Glob tool, or use 'rtk proxy ls'/'rtk proxy find' (raw). A \"(empty)\" from a lossy channel means UNKNOWN, not absent."

	# Always (when present): the cross-project backport queue.
	if [ -f "$lessons_store/README.md" ]; then
		printf '%s\n' "[cross-project-context] Global scaffolding-lessons store (backport queue, NOT auto-loaded): $lessons_store/README.md — read it before planning any BlueprintX template work."
	fi

	# Always (when present): the per-project corrections log. Surfaced here (not in CLAUDE.md)
	# so the always-on prompt stays lean; read it and apply entries scoped to this cwd or global.
	if [ -f "$claude_dir/tasks/lessons.md" ]; then
		printf '%s\n' "[cross-project-context] Corrections log (NOT auto-loaded): $claude_dir/tasks/lessons.md — read it and immediately apply any entry whose Scope matches this working directory or is 'global'. Append a new entry whenever the user corrects a mistake (see the s:capturing-lessons skill)."
	fi

	# When present: the capture-audit handoff written by session_capture_audit.sh at
	# the LAST session's end (it can only report forward — the session was over). Surface
	# the unresolved gaps as the first thing this session sees, then clear the file so it
	# fires once. The fixer is /session-closeout, run live.
	local slug handoff
	slug="$(printf '%s' "$cwd" | tr '/' '-')"
	handoff="$claude_dir/session-audit/$slug.md"
	if [ -f "$handoff" ]; then
		printf '%s\n' "[session-capture-audit] Unresolved capture gaps from your last session in this repo (run /session-closeout to resolve):"
		cat "$handoff"
		rm -f "$handoff" 2>/dev/null || true
	fi

	# BlueprintX template repo OR a scaffolded project → point at proving-ground memory.
	local blueprintx_mirror
	blueprintx_mirror="$(mirror_path "$cwd" "blueprintx-lessons")"
	local is_blueprintx=0
	shopt -s nullglob
	local skeleton_metas=("$cwd"/templates/*/skeleton.meta)
	shopt -u nullglob
	if [ -f "$blueprintx_mirror" ] || [ "${#skeleton_metas[@]}" -gt 0 ] || [ -f "$cwd/bin/blueprintx.sh" ]; then
		is_blueprintx=1
	fi

	if [ "$is_blueprintx" -eq 1 ]; then
		printf '%s\n' "[cross-project-context] This is a BlueprintX repo or a BlueprintX-scaffolded project:"
		[ -f "$blueprintx_mirror" ] && printf '%s\n' "  - This repo's git-ignored, GENERATED lessons mirror: $blueprintx_mirror"
		[ -d "$proving_mem" ] && printf '%s\n' "  - Proving-ground project memory (NOT auto-loaded here): $proving_mem"
		printf '%s\n' "  - Do NOT edit/branch/PR ~/github/blueprintx templates unless the user explicitly asks in the current request; capture generalizable findings in the BlueprintX store, then run 'make lessons_mirror' (or the deployed generator) to refresh $blueprintx_mirror."
	fi
}

# "Awaiting review" = no review lands on the CURRENT head commit (a review of a superseded
# commit is not a review — blueprintx#220). $json is `gh pr list --state all --json
# number,url,state,headRefName,headRefOid,reviews,createdAt` — the SAME payload the worktree
# loop below reuses for the "no PR" branch check, so this is the repo's only `gh` call.
fanout_pr_summary() {
	local json="$1"
	printf '%s' "$json" | jq -r '
		[ .[] | select(.state=="OPEN") ] as $open
		| ($open | length) as $nopen
		| [ $open[] | . as $pr
		    | select((($pr.reviews // []) | any(.commit.oid == $pr.headRefOid)) | not) ] as $awaiting
		| ($awaiting | length) as $nawait
		| if $nawait == 0 then empty else
		    ($awaiting | sort_by(.createdAt) | .[0]) as $oldest
		    | ((now - ($oldest.createdAt | fromdateiso8601)) / 3600 | floor) as $hrs
		    | "[fan-out] \($nopen) PR(s) open · \($nawait) awaiting review (oldest #\($oldest.number), \($hrs)h)"
		  end
	' 2>/dev/null
}

# classify_worktree_diff() and fanout_worktrees() live in lib/worktree_fanout.sh (sourced
# above) — dotfiles-dev#383 extracted them so quota_gap_rescue.sh (UserPromptSubmit) can call
# the same implementation instead of re-deriving it.

# Outstanding fan-out state (dotfiles-dev#160): PRs waiting on a review of the current head
# commit, worktrees with unpushed commits or uncommitted files, and branches pushed with no PR.
# Silent when clean — this is a janitor, never a gate (bin/CLAUDE.md): report and exit 0, never
# block, never fail the session. A `gh` failure prints an explicit "could not reach GitHub" line
# so it is never confused with the true "nothing open" silence.
emit_fanout_status() {
	local cwd
	cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
	git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

	local slug="" json="" github_ok=0
	slug="$(fanout_repo_slug "$cwd")"
	if [ -n "$slug" ]; then
		if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
			printf '%s\n' "[fan-out] gh/jq not available — could not reach GitHub for PR/review status"
		else
			json="$(fanout_pr_json "$slug")"
			if printf '%s' "$json" | jq -e 'type=="array"' >/dev/null 2>&1; then
				github_ok=1
				fanout_pr_summary "$json"
			else
				printf '%s\n' "[fan-out] could not reach GitHub — PR/review status unknown"
			fi
		fi
	fi

	fanout_worktrees "$cwd" "$github_ok" "$json"
}

main() {
	emit_cross_project_context
	emit_deploy_drift_status
	emit_fanout_status
	emit_reviewer_probe_status
	exit 0
}

# Source-guarded so tests can `source` this file to unit-test individual functions
# (e.g. classify_worktree_diff) without triggering the SessionStart payload + exit 0.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
