#!/bin/bash
# PreToolUse (Bash matcher) hook: thin pre-filter in front of `rtk hook claude`, so a
# worktree-isolated agent can still run git (dotfiles-linux-dev#417).
#
# The deadlock: `rtk hook claude` rewrites a bare `git status` into `rtk git status` at
# execution time (RTK.md documents this as intentional — token savings). The harness's own
# worktree-isolation guard runs AFTER every PreToolUse hook has resolved the final command, and
# it refuses an `rtk`-prefixed git invocation it cannot statically prove targets the agent's own
# worktree ("cannot be read here"). That guard's text is not a hook in this repo — it is
# harness-level, not ours to change — so the only lever we own is making sure git never reaches
# it already rewritten. Measured 2026-09-20: bare `git status`, `rtk git status`, `rtk proxy git
# status`, and a Python subprocess call were ALL refused identically inside a harness-provisioned
# worktree, while `/usr/bin/git -C <path> ...` (a plain, unambiguous invocation) always worked.
#
# Fix: when this session's cwd is a harness-provisioned isolated worktree (its own naming
# convention: `.claude/worktrees/agent-<id>/`, distinct from a worktree an agent creates itself
# under any other name) and the command is a git invocation, strip any `rtk`/`rtk proxy` prefix
# and let the plain `git ...` form run unrewritten instead of handing it to `rtk hook claude`.
# Every other command, and every session outside such a worktree, is unaffected — this is a
# pre-filter, not a replacement for rtk's rewrite engine.
#
# Hook I/O contract (same as protected_branch_guard.sh): allow is silent-stdout + exit 0 (either
# truly silent, or a passthrough JSON rewrite via updatedInput); it never blocks (exit 2) — a
# false negative here just costs the normal token-saving rewrite, never a broken command. Fails
# open to the normal `rtk hook claude` call on anything it cannot resolve (no jq, unparsable
# payload, cwd not reported).
set -u

# jq parses the hook payload; without it we cannot classify the command, so fail open to the
# normal rewrite path. Checked BEFORE reading stdin so `exec` hands rtk an untouched pipe.
command -v jq >/dev/null 2>&1 || exec rtk hook claude

payload="$(cat)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"

# Harness-provisioned isolated worktree only — a worktree an agent creates itself (any other
# name) is not this case, and behaves exactly as before.
if [[ "$cwd" =~ /\.claude/worktrees/agent-[^/]+(/|$) ]]; then
	stripped="$(printf '%s' "$cmd" | sed -E 's/^[[:space:]]*rtk[[:space:]]+(proxy[[:space:]]+)?//')"
	if [[ "$stripped" =~ ^[[:space:]]*git([[:space:]]|$) ]]; then
		if [ "$stripped" != "$cmd" ]; then
			# Was typed/rewritten as an rtk form — hand back the stripped, plain form.
			jq -nc --arg cmd "$stripped" \
				'{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecisionReason:"worktree-isolated agent: pass git through unrewritten (dotfiles-linux-dev#417)",updatedInput:{command:$cmd}}}'
		fi
		# Already bare git: silent allow, nothing to rewrite.
		exit 0
	fi
fi

printf '%s' "$payload" | rtk hook claude
