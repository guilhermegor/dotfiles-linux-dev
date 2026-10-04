#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/session_capture_audit.sh
#
# Focus: the both-directions completeness table (dotfiles-linux-dev#81). A one-directional
# lessons→issues audit hid an OPEN ISSUE with no lesson (#75); these tests pin both rows.
#
# Strategy:
#   - Point the hook's store at a throwaway CLAUDE_CONFIG_DIR so we control the lessons.
#   - Run inside a git repo with a github origin, so repo_slug resolves (dotfiles-linux-dev#94:
#     every LESSON_STORES entry is audited regardless of the repo's basename — there is
#     no more repo-name gate to satisfy).
#   - Stub `gh` on PATH to feed a deterministic open-issue list (no network).
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
	HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/session_capture_audit.sh"
	TEST_TMP="$(mktemp -d)"

	# Throwaway store, matching the claude-toolchain lesson-store layout.
	export CLAUDE_CONFIG_DIR="$TEST_TMP/claude"
	STORE="$CLAUDE_CONFIG_DIR/memory/lessons-claude-toolchain"
	mkdir -p "$STORE"
	printf '# index\n' >"$STORE/README.md"

	# A repo whose basename is a store target, with a github origin.
	REPO="$TEST_TMP/dotfiles-dev"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" remote add origin https://github.com/guilhermegor/dotfiles-dev.git

	# gh stub: prints whatever issue numbers $GH_ISSUES holds, as the --json/--jq path does.
	mkdir -p "$TEST_TMP/bin"
	cat >"$TEST_TMP/bin/gh" <<'STUB'
#!/bin/bash
# Only implements `gh issue list … --jq '.[].number'` → one number per line.
# Records its own argv so a test can prove the caller bounded the page explicitly.
printf '%s\n' "$*" >>"$GH_ARGV_LOG"
printf '%s\n' $GH_ISSUES
STUB
	chmod +x "$TEST_TMP/bin/gh"
}

teardown() {
	rm -rf "$TEST_TMP"
}

# Indexed lesson referencing the given dotfiles-dev issue number (or none if $2 empty).
lesson() {
	local name="$1" issue="$2"
	printf '# %s\n\n- **Tier:** language-common\n' "$name" >"$STORE/$name"
	[ -n "$issue" ] && printf -- '- **PR:** guilhermegor/dotfiles-dev#%s\n' "$issue" >>"$STORE/$name"
	printf -- '- %s\n' "$name" >>"$STORE/README.md"
}

# Lesson carrying an explicit `Status:` line — the disposition, not just a citation.
lesson_status() {
	local name="$1" status="$2"
	printf '# %s\n\n- **Tier:** language-common\n- **Status:** %s\n' "$name" "$status" \
		>"$STORE/$name"
	printf -- '- %s\n' "$name" >>"$STORE/README.md"
}

run_report() {
	run bash -c "cd '$REPO' && PATH='$TEST_TMP/bin:$PATH' GH_ISSUES='$1' \
		GH_ARGV_LOG='$TEST_TMP/gh_argv' bash '$HOOK' </dev/null"
}

# --- row 1: lessons → issues (store-internal, no network) ---------------------------------------
#
# dotfiles-linux-dev#138: a lesson with a `delivered`/`advisory`/`superseded` Status and no PR
# citation is NOT debt — only `queued`/`tracked`/a missing Status line is genuinely owed.
# The old behaviour lumped every Status value (including queued) into "declared" and only
# flagged the true no-Status-no-ref case; these tests pin the corrected buckets.

@test "row 1 flags a lesson with no Status and no reference as genuinely unaccounted" {
	lesson "orphan-lesson.md" ""
	run_report ""
	[ "$status" -eq 0 ]
	[[ "$output" == *"lessons → issues : 1 in store, 1 without a PR ref — 0 delivered, 0 advisory, 0 superseded, 1 genuinely unaccounted"* ]]
	[[ "$output" == *"genuinely unaccounted"*"orphan-lesson.md"* ]]
	[[ "$output" == *"[lessons] 'orphan-lesson.md' has no **Status:** line"* ]]
}

@test "row 1 counts a lesson that references its issue as accounted for" {
	lesson "tracked-lesson.md" "42"
	run_report ""
	[[ "$output" == *"lessons → issues : 1 in store, 0 without a PR ref — 0 delivered, 0 advisory, 0 superseded, 0 genuinely unaccounted"* ]]
	[[ "$output" != *"genuinely unaccounted"*"tracked-lesson.md"* ]]
}

@test "row 1 excludes a delivered Status with no issue number from the debt count" {
	# The whole point of the field: work that shipped before issues existed is not debt.
	lesson_status "shipped.md" "delivered — pre-PR (abc1234)"
	run_report ""
	[[ "$output" == *"lessons → issues : 1 in store, 1 without a PR ref — 1 delivered, 0 advisory, 0 superseded, 0 genuinely unaccounted"* ]]
}

@test "row 1 excludes an advisory Status from the debt count" {
	lesson_status "judgment.md" "advisory — no scaffold target"
	run_report ""
	[[ "$output" == *"lessons → issues : 1 in store, 1 without a PR ref — 0 delivered, 1 advisory, 0 superseded, 0 genuinely unaccounted"* ]]
}

@test "row 1 excludes a superseded Status from the debt count" {
	lesson_status "old-rule.md" "superseded — replaced by the newer rule"
	run_report ""
	[[ "$output" == *"lessons → issues : 1 in store, 1 without a PR ref — 0 delivered, 0 advisory, 1 superseded, 0 genuinely unaccounted"* ]]
}

@test "row 1 negative control: a queued Status with no PR reference still counts as debt" {
	lesson_status "owed.md" "queued — no issue filed (target absent)"
	run_report ""
	[[ "$output" == *"lessons → issues : 1 in store, 1 without a PR ref — 0 delivered, 0 advisory, 0 superseded, 1 genuinely unaccounted"* ]]
	[[ "$output" == *"genuinely unaccounted"*"owed.md"* ]]
}

@test "row 1 negative control: a tracked Status with no PR reference still counts as debt" {
	lesson_status "tracked.md" "tracked — awaiting scheduling"
	run_report ""
	[[ "$output" == *"lessons → issues : 1 in store, 1 without a PR ref — 0 delivered, 0 advisory, 0 superseded, 1 genuinely unaccounted"* ]]
	[[ "$output" == *"genuinely unaccounted"*"tracked.md"* ]]
}

# --- row 2: issues → lessons (the B-side orphan the old audit could not see) --------------------

@test "row 2 flags an open issue with no lesson as an orphan" {
	lesson "some-lesson.md" "42"
	run_report "77"
	[[ "$output" == *"issues  → lessons: 1 open, 0 sourced by a lesson, 1 orphan"* ]]
	[[ "$output" == *"open issues with no lesson"*"#77"* ]]
}

@test "row 2 counts an open issue referenced by a lesson as sourced" {
	lesson "some-lesson.md" "42"
	run_report "42"
	[[ "$output" == *"issues  → lessons: 1 open, 1 sourced by a lesson, 0 orphan"* ]]
	[[ "$output" != *"open issues with no lesson"* ]]
}

@test "issue #7 is not matched by a lesson referencing #75 (digit-boundary)" {
	lesson "seventyfive.md" "75"
	run_report "7"
	[[ "$output" == *"1 open, 0 sourced by a lesson, 1 orphan"* ]]
	[[ "$output" == *"#7"* ]]
}

@test "row 2 bounds the issue page explicitly instead of taking gh's default 30" {
	# Measured blueprintx 2026-08-16: without --limit the audit saw 30 of 46 open issues and
	# reported the orphan count over that silent sample.
	lesson "some-lesson.md" "42"
	run_report "42"
	[[ "$(cat "$TEST_TMP/gh_argv")" == *"--limit"* ]]
}

# --- SessionEnd must NEVER hit the network (the fail-open guarantee) ----------------------------

@test "handoff mode does not invoke gh (no network at SessionEnd)" {
	lesson "some-lesson.md" "42"
	# A gh that records the fact it was called; handoff mode must never trigger it.
	cat >"$TEST_TMP/bin/gh" <<STUB
#!/bin/bash
touch "$TEST_TMP/gh-was-called"
STUB
	chmod +x "$TEST_TMP/bin/gh"
	# --handoff writes to a file (not stdout) and only when there are gaps; the point
	# of the test is the side effect, so we just assert gh was never reached.
	run bash -c "cd '$REPO' && PATH='$TEST_TMP/bin:$PATH' bash '$HOOK' --handoff </dev/null"
	[ "$status" -eq 0 ]
	[ ! -e "$TEST_TMP/gh-was-called" ]
}

# --- report mode with no resolvable repo: row 2 skipped, never an error -------------------------

@test "row 2 is skipped (not errored) when the repo has no github origin" {
	lesson "some-lesson.md" "42"
	# Drop the origin: repo_slug returns empty, so row 2 has nothing to query. The
	# basename stays "dotfiles-dev" so the table still renders (row 1 unaffected).
	git -C "$REPO" remote remove origin
	run bash -c "cd '$REPO' && PATH='$TEST_TMP/bin:$PATH' bash '$HOOK' </dev/null"
	[ "$status" -eq 0 ]
	[[ "$output" == *"issues  → lessons: skipped"* ]]
}

# --- dotfiles-linux-dev#94: the table must emit in ANY repo, not just the two whose basename ------------
# happens to equal a store's backport target ("blueprintx" / "dotfiles-dev"). The old
# `store_dir_for_repo("$repo")` answered "which store backports INTO this repo?" and
# `return 0`d silently — no header, nothing — the instant no store matched. Every other
# repo (where the table is actually meant to help) got a bare "Mechanical checks: clean"
# with zero signal that completeness was never computed. This is the negative control: it
# must FAIL on the pre-#94 implementation and PASS after the fix.

@test "the completeness table emits in a repo that is neither blueprintx nor dotfiles-dev" {
	OTHER_REPO="$TEST_TMP/filings-cvm"
	mkdir -p "$OTHER_REPO"
	git -C "$OTHER_REPO" init -q
	git -C "$OTHER_REPO" remote add origin https://github.com/guilhermegor/filings-cvm.git

	lesson "some-lesson.md" "42"
	run bash -c "cd '$OTHER_REPO' && PATH='$TEST_TMP/bin:$PATH' GH_ISSUES='' \
		GH_ARGV_LOG='$TEST_TMP/gh_argv' bash '$HOOK' </dev/null"
	[ "$status" -eq 0 ]
	[[ "$output" == *"--- completeness (both directions, dotfiles-linux-dev#81) ---"* ]]
	[[ "$output" == *"[claude-toolchain-lessons]"* ]]
	[[ "$output" == *"lessons → issues :"* ]]
}

# --- check_mirrors: the audit's actual join rule (dotfiles-linux-dev#315) ---------------------------
#
# lesson_capture_checkpoint.sh's reminder claims (now correctly) that the mirror check matches
# on the bare filename appearing anywhere in the mirror text. Pin that here directly against
# check_mirrors()'s real behaviour — `grep -qF "$name" "$mirror"` — so the two files cannot
# silently re-diverge. Uses a repo that is neither store's backport target (lessons-claude-toolchain's
# target set is dotfiles-dev/dotfiles-linux-dev/dotfiles-macos-dev/dotfiles-linux-prod), since
# check_mirrors() skips the same-repo mirror entirely otherwise.

@test "check_mirrors accepts a mirror entry containing only the bare filename" {
	OTHER_REPO="$TEST_TMP/filings-cvm"
	mkdir -p "$OTHER_REPO/.specs/_lessons"
	git -C "$OTHER_REPO" init -q
	git -C "$OTHER_REPO" remote add origin https://github.com/guilhermegor/filings-cvm.git

	printf '# origin-lesson\n\n- **Tier:** language-common\n- **Origin:** filings-cvm\n' \
		>"$STORE/origin-lesson.md"
	printf -- '- origin-lesson.md\n' >>"$STORE/README.md"

	# Only the bare filename, mid-sentence — no "- **Source:**" field. This is exactly
	# what the corrected checkpoint reminder now promises is sufficient.
	printf 'Ported over: origin-lesson.md\n' >"$OTHER_REPO/.specs/_lessons/claude-toolchain-lessons.md"

	run bash -c "cd '$OTHER_REPO' && PATH='$TEST_TMP/bin:$PATH' GH_ISSUES='' \
		GH_ARGV_LOG='$TEST_TMP/gh_argv' bash '$HOOK' </dev/null"
	[ "$status" -eq 0 ]
	[[ "$output" != *"origin-lesson.md' originated here but is not in .specs/_lessons/claude-toolchain-lessons.md"* ]]
}

@test "check_mirrors still flags a mirror missing the filename entirely (non-vacuous control)" {
	OTHER_REPO="$TEST_TMP/filings-cvm"
	mkdir -p "$OTHER_REPO/.specs/_lessons"
	git -C "$OTHER_REPO" init -q
	git -C "$OTHER_REPO" remote add origin https://github.com/guilhermegor/filings-cvm.git

	printf '# origin-lesson\n\n- **Tier:** language-common\n- **Origin:** filings-cvm\n' \
		>"$STORE/origin-lesson.md"
	printf -- '- origin-lesson.md\n' >>"$STORE/README.md"

	printf 'nothing relevant here\n' >"$OTHER_REPO/.specs/_lessons/claude-toolchain-lessons.md"

	run bash -c "cd '$OTHER_REPO' && PATH='$TEST_TMP/bin:$PATH' GH_ISSUES='' \
		GH_ARGV_LOG='$TEST_TMP/gh_argv' bash '$HOOK' </dev/null"
	[ "$status" -eq 0 ]
	[[ "$output" == *"origin-lesson.md' originated here but is not in .specs/_lessons/claude-toolchain-lessons.md"* ]]
}

@test "a store absent from disk is reported as skipped, never silently omitted" {
	# blueprintx-lessons is never created by setup(); the header for it must still
	# print "skipped" — a missing store must never look identical to "checked and clean".
	OTHER_REPO="$TEST_TMP/filings-cvm"
	mkdir -p "$OTHER_REPO"
	git -C "$OTHER_REPO" init -q
	git -C "$OTHER_REPO" remote add origin https://github.com/guilhermegor/filings-cvm.git

	lesson "some-lesson.md" "42"
	run bash -c "cd '$OTHER_REPO' && PATH='$TEST_TMP/bin:$PATH' bash '$HOOK' </dev/null"
	[ "$status" -eq 0 ]
	[[ "$output" == *"[blueprintx-lessons] skipped (store not on disk"* ]]
	[[ "$output" == *"[lessons-other] skipped (store not on disk"* ]]
}

# --- PR #546 review: LESSON_STORES ships via `make ai_clients`, `~/.claude/memory/`
# ships via nothing — a machine that renamed the registry entry without moving its
# directory must not have every check here read the toolchain store as absent.

@test "check_lessons and emit_completeness fall back to the legacy lessons-dotfiles dir" {
	LEGACY="$CLAUDE_CONFIG_DIR/memory/lessons-dotfiles"
	mv "$STORE" "$LEGACY"
	printf '# some-lesson.md\n\n- **Tier:** language-common\n- **Origin:** filings-cvm\n' \
		>"$LEGACY/some-lesson.md"
	printf -- '- some-lesson.md\n' >>"$LEGACY/README.md"

	OTHER_REPO="$TEST_TMP/filings-cvm"
	mkdir -p "$OTHER_REPO"
	git -C "$OTHER_REPO" init -q
	git -C "$OTHER_REPO" remote add origin https://github.com/guilhermegor/filings-cvm.git

	run bash -c "cd '$OTHER_REPO' && PATH='$TEST_TMP/bin:$PATH' bash '$HOOK' </dev/null"
	[ "$status" -eq 0 ]
	[[ "$output" == *"[claude-toolchain-lessons] using legacy path"* ]]
	[[ "$output" != *"[claude-toolchain-lessons] skipped"* ]]
	# check_lessons() must find the legacy README index and NOT flag a lost lesson.
	[[ "$output" != *"'some-lesson.md' is not in the"* ]]
	[[ "$output" != *"has lesson files but no README index"* ]]
}

@test "still reports skipped (never a false legacy match) when neither directory exists" {
	rm -rf "$STORE"
	OTHER_REPO="$TEST_TMP/filings-cvm"
	mkdir -p "$OTHER_REPO"
	git -C "$OTHER_REPO" init -q
	git -C "$OTHER_REPO" remote add origin https://github.com/guilhermegor/filings-cvm.git

	run bash -c "cd '$OTHER_REPO' && PATH='$TEST_TMP/bin:$PATH' bash '$HOOK' </dev/null"
	[ "$status" -eq 0 ]
	[[ "$output" == *"[claude-toolchain-lessons] skipped (store not on disk"* ]]
	[[ "$output" != *"using legacy path"* ]]
}

# --- lessons-other: the third store, no distinct backport target (dotfiles-linux-dev#356) -------------

@test "lessons-other never expects a repo mirror even when Origin matches the current repo" {
	OTHER_STORE="$CLAUDE_CONFIG_DIR/memory/lessons-other"
	mkdir -p "$OTHER_STORE" "$REPO/.specs/_lessons"
	printf '# index\n- standalone-fix.md\n' >"$OTHER_STORE/README.md"
	printf '# standalone-fix\n\n- **Status:** delivered\n- **Origin:** dotfiles-dev\n' \
		>"$OTHER_STORE/standalone-fix.md"

	# REPO's basename ("dotfiles-dev") IS a backport target for the OTHER two stores, so
	# if the "-" sentinel were ignored, this would misfire as a missing-mirror gap.
	run bash -c "cd '$REPO' && PATH='$TEST_TMP/bin:$PATH' GH_ISSUES='' \
		GH_ARGV_LOG='$TEST_TMP/gh_argv' bash '$HOOK' </dev/null"
	[ "$status" -eq 0 ]
	[[ "$output" != *"standalone-fix.md' originated here but"* ]]
	[[ "$output" == *"[lessons-other]"* ]]
}

# --- check_mirrors: an append that changes the file after its mirror was last touched -----------
# (dotfiles-linux-dev#356's first gap: filename-only matching can't see an append to an EXISTING lesson,
# since the presence check passed the moment the lesson was first created.)

@test "check_mirrors flags a lesson that changed after its mirror was last touched" {
	OTHER_REPO="$TEST_TMP/filings-cvm"
	mkdir -p "$OTHER_REPO/.specs/_lessons"
	git -C "$OTHER_REPO" init -q
	git -C "$OTHER_REPO" remote add origin https://github.com/guilhermegor/filings-cvm.git

	printf '# origin-lesson\n\n- **Tier:** language-common\n- **Status:** delivered\n- **Origin:** filings-cvm\n' \
		>"$STORE/origin-lesson.md"
	printf -- '- origin-lesson.md\n' >>"$STORE/README.md"
	printf 'Ported over: origin-lesson.md\n' >"$OTHER_REPO/.specs/_lessons/claude-toolchain-lessons.md"

	# Mirror written first, then the lesson appended to afterwards — the append never
	# propagated, and filename presence alone can't see that.
	touch -d '2026-09-01T00:00:00' "$OTHER_REPO/.specs/_lessons/claude-toolchain-lessons.md"
	touch -d '2026-09-02T00:00:00' "$STORE/origin-lesson.md"

	run bash -c "cd '$OTHER_REPO' && PATH='$TEST_TMP/bin:$PATH' GH_ISSUES='' \
		GH_ARGV_LOG='$TEST_TMP/gh_argv' bash '$HOOK' </dev/null"
	[ "$status" -eq 0 ]
	[[ "$output" == *"origin-lesson.md' changed after .specs/_lessons/claude-toolchain-lessons.md"* ]]
}

@test "check_mirrors does not flag a lesson touched before its mirror (negative control)" {
	OTHER_REPO="$TEST_TMP/filings-cvm"
	mkdir -p "$OTHER_REPO/.specs/_lessons"
	git -C "$OTHER_REPO" init -q
	git -C "$OTHER_REPO" remote add origin https://github.com/guilhermegor/filings-cvm.git

	printf '# origin-lesson\n\n- **Tier:** language-common\n- **Status:** delivered\n- **Origin:** filings-cvm\n' \
		>"$STORE/origin-lesson.md"
	printf -- '- origin-lesson.md\n' >>"$STORE/README.md"
	printf 'Ported over: origin-lesson.md\n' >"$OTHER_REPO/.specs/_lessons/claude-toolchain-lessons.md"

	# Lesson written first, mirror updated afterwards — fully propagated, no staleness.
	touch -d '2026-09-01T00:00:00' "$STORE/origin-lesson.md"
	touch -d '2026-09-02T00:00:00' "$OTHER_REPO/.specs/_lessons/claude-toolchain-lessons.md"

	run bash -c "cd '$OTHER_REPO' && PATH='$TEST_TMP/bin:$PATH' GH_ISSUES='' \
		GH_ARGV_LOG='$TEST_TMP/gh_argv' bash '$HOOK' </dev/null"
	[ "$status" -eq 0 ]
	[[ "$output" != *"origin-lesson.md' changed after"* ]]
}

# --- dotfiles-linux-dev#536: repo identity via remote, and the declared alias set ---------------------

@test "identity resolves via the remote and says so, even when the directory name differs" {
	# The renamed-repo case: directory still called "dotfiles-dev" locally, but the
	# remote already points at the new name — the report must say which repo AND
	# which signal, so a mismatch is visible instead of silently assumed.
	git -C "$REPO" remote set-url origin https://github.com/guilhermegor/dotfiles-linux-dev.git
	lesson "some-lesson.md" "42"
	run_report ""
	[[ "$output" == *"=== Session capture audit — dotfiles-linux-dev via remote"* ]]
}

@test "a citation written before the rename still counts as accounted for after it" {
	# lesson() stamps "guilhermegor/dotfiles-linux-dev#42" (the pre-rename citation shape).
	# Once the remote points at dotfiles-linux-dev, repo resolves to the NEW name —
	# the citation must still match via the store's declared alias set, not a fresh
	# literal string comparison, or ~242 real lessons would all flip to "unaccounted".
	git -C "$REPO" remote set-url origin https://github.com/guilhermegor/dotfiles-linux-dev.git
	lesson "tracked-lesson.md" "42"
	run_report ""
	[[ "$output" == *"lessons → issues : 1 in store, 0 without a PR ref — 0 delivered, 0 advisory, 0 superseded, 0 genuinely unaccounted"* ]]
}

@test "the same run behaves identically for a dotfiles-dev vs dotfiles-linux-dev checkout" {
	# Acceptance proof: same lesson content, only the checkout directory name (and
	# matching remote) differ — the completeness row must be byte-identical.
	RENAMED_REPO="$TEST_TMP/dotfiles-linux-dev"
	mkdir -p "$RENAMED_REPO"
	git -C "$RENAMED_REPO" init -q
	git -C "$RENAMED_REPO" remote add origin https://github.com/guilhermegor/dotfiles-linux-dev.git

	lesson "tracked-lesson.md" "42"
	run_report ""
	old_line="$(printf '%s\n' "$output" | grep 'lessons → issues :')"

	run bash -c "cd '$RENAMED_REPO' && PATH='$TEST_TMP/bin:$PATH' GH_ISSUES='' \
		GH_ARGV_LOG='$TEST_TMP/gh_argv' bash '$HOOK' </dev/null"
	new_line="$(printf '%s\n' "$output" | grep 'lessons → issues :')"

	[ "$old_line" = "$new_line" ]
}
