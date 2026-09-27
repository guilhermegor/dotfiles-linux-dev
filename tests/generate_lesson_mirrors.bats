#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/generate_lesson_mirrors.sh
# (dotfiles-dev#386): the mirror under .specs/_lessons/ is GENERATED from the
# global lesson stores, never hand-typed. These tests pin:
#   - a lesson whose Origin names the target repo IS mirrored
#   - a lesson whose Origin does NOT name it is excluded
#   - the same-repo store (target_repo == repo) is skipped, matching the
#     convention session_capture_audit.sh's check_mirrors() already enforces
#   - lessons-other (the "-" sentinel) is never mirrored anywhere
#   - regeneration is idempotent (running twice produces byte-identical output)
#   - a repo with no .specs/ at all gets one created, holding only _lessons/
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
	GEN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/generate_lesson_mirrors.sh"
	TEST_TMP="$(mktemp -d)"

	export CLAUDE_CONFIG_DIR="$TEST_TMP/claude"
	BX_STORE="$CLAUDE_CONFIG_DIR/memory/lessons"
	DF_STORE="$CLAUDE_CONFIG_DIR/memory/lessons-dotfiles"
	OTHER_STORE="$CLAUDE_CONFIG_DIR/memory/lessons-other"
	mkdir -p "$BX_STORE" "$DF_STORE" "$OTHER_STORE"

	REPO="$TEST_TMP/dotfiles-dev"
	mkdir -p "$REPO"
}

teardown() {
	rm -rf "$TEST_TMP"
}

# A minimal, well-formed lesson file in $1/$2.md with the given Origin ($3).
lesson() {
	local store="$1" name="$2" origin="$3"
	printf '# %s\n\n- **Tier:** language-common\n- **Lesson:** one sentence.\n- **Why:** one sentence.\n- **Origin:** %s\n' \
		"$name" "$origin" >"$store/$name.md"
}

@test "a lesson whose Origin names the repo is included in the mirror" {
	lesson "$BX_STORE" "matches-repo" "dotfiles-dev"
	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	[ -f "$REPO/.specs/_lessons/blueprintx-lessons.md" ]
	grep -qF "matches-repo.md" "$REPO/.specs/_lessons/blueprintx-lessons.md"
}

@test "a lesson whose Origin does not name the repo is excluded" {
	lesson "$BX_STORE" "matches-repo" "dotfiles-dev"
	lesson "$BX_STORE" "other-origin" "filings-cvm"
	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	run grep -qF "other-origin.md" "$REPO/.specs/_lessons/blueprintx-lessons.md"
	[ "$status" -ne 0 ]
}

@test "the same-repo store mirror is never generated (target_repo == repo)" {
	lesson "$DF_STORE" "toolchain-fix" "dotfiles-dev"
	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	[ ! -e "$REPO/.specs/_lessons/dotfiles-dev-lessons.md" ]
}

@test "lessons-other is never mirrored, even when Origin matches the repo" {
	lesson "$OTHER_STORE" "standalone-fix" "dotfiles-dev"
	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	[ ! -e "$REPO/.specs/_lessons/lessons-other.md" ]
}

@test "regeneration is idempotent: running twice produces byte-identical output" {
	lesson "$BX_STORE" "matches-repo" "dotfiles-dev"
	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	cp "$REPO/.specs/_lessons/blueprintx-lessons.md" "$TEST_TMP/first-run.md"
	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	diff "$TEST_TMP/first-run.md" "$REPO/.specs/_lessons/blueprintx-lessons.md"
}

@test "a repo with no .specs/ at all gets one created, holding only _lessons/" {
	lesson "$BX_STORE" "matches-repo" "dotfiles-dev"
	[ ! -e "$REPO/.specs" ]
	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	[ -d "$REPO/.specs/_lessons" ]
	[ ! -e "$REPO/.specs/CLAUDE.md" ]
}

# Cross-check against the checker: what generate_lesson_mirrors.sh writes here must
# satisfy session_capture_audit.sh's check_mirrors() — both source the same predicate
# (lib/lesson_mirrors.sh), so this proves the sharing actually holds end to end.
@test "a generated mirror satisfies session_capture_audit.sh's check_mirrors" {
	AUDIT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/session_capture_audit.sh"
	printf '# index\n- matches-repo.md\n' >"$BX_STORE/README.md"
	lesson "$BX_STORE" "matches-repo" "dotfiles-dev"
	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]

	git -C "$REPO" init -q
	git -C "$REPO" remote add origin https://github.com/guilhermegor/dotfiles-dev.git
	run bash -c "cd '$REPO' && bash '$AUDIT' </dev/null"
	[ "$status" -eq 0 ]
	[[ "$output" != *"matches-repo.md' originated here but"* ]]
}

# --- PR #388 review: the Origin predicate -------------------------------------
# `-` is a non-word character, so a `\b${repo}\b` search matched `dotfiles-dev`
# inside `not-dotfiles-dev`. Every repo name in use contains a dash.

@test "an Origin that only CONTAINS the repo name is excluded (not-dotfiles-dev)" {
	lesson "$BX_STORE" "lookalike" "not-dotfiles-dev, 2026-09-14"
	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	run grep -qF "lookalike.md" "$REPO/.specs/_lessons/blueprintx-lessons.md"
	[ "$status" -ne 0 ]
}

# The two real Origin shapes a literal whole-field compare would drop (8 of 43 real
# lessons in lessons-dotfiles were written this way, measured 2026-09-14).
@test "a two-repo Origin (blueprintx / dotfiles-dev) is included for either repo" {
	lesson "$BX_STORE" "shared-finding" "blueprintx / dotfiles-dev (2026-08-17), after x"
	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	grep -qF "shared-finding.md" "$REPO/.specs/_lessons/blueprintx-lessons.md"
}

@test "an Origin carrying an issue ref (dotfiles-dev#344) is included" {
	lesson "$BX_STORE" "issue-ref" "dotfiles-dev#344 (closed not-planned), #345 filed"
	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	grep -qF "issue-ref.md" "$REPO/.specs/_lessons/blueprintx-lessons.md"
}

@test "a repo cited after the comma as a SOURCE is not treated as the Origin" {
	FC="$TEST_TMP/filings-cvm"
	mkdir -p "$FC"
	lesson "$BX_STORE" "cited-source" "dotfiles-dev#126 / PR #127, from filings-cvm #180."
	run bash "$GEN" "$FC"
	[ "$status" -eq 0 ]
	run grep -qF "cited-source.md" "$FC/.specs/_lessons/blueprintx-lessons.md"
	[ "$status" -ne 0 ]
}

# --- PR #388 review: failures must surface ------------------------------------
# The generator runs under `set -uo pipefail`, NOT `-e`.

@test "an invalid repository root is rejected, and nothing is written under /" {
	lesson "$BX_STORE" "matches-repo" "dotfiles-dev"
	run bash "$GEN" "$TEST_TMP/does-not-exist"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Invalid repository root"* ]]
}

@test "a failed mirror write fails the whole run instead of reporting success" {
	lesson "$BX_STORE" "matches-repo" "dotfiles-dev"
	# A regular FILE where the directory must go makes `mkdir -p .specs/_lessons` fail.
	printf 'not a directory\n' >"$REPO/.specs"
	run bash "$GEN" "$REPO"
	[ "$status" -ne 0 ]
}

# --- The mirror moved in #386 and nothing cleaned up behind it, so repos still carry a pre-move
# --- docs/<base>.md that no longer regenerates. Warn, never delete, and never alter the status.

@test "a retired docs/<base>.md carrying the generated header is reported as safe to delete" {
	lesson "$BX_STORE" "matches-repo" "dotfiles-dev"
	mkdir -p "$REPO/docs"
	printf '<!-- GENERATED by generate_lesson_mirrors.sh (make lessons_mirror) — do not hand-edit.\n' \
		>"$REPO/docs/blueprintx-lessons.md"
	printf 'stale pre-#386 mirror\n' >>"$REPO/docs/blueprintx-lessons.md"

	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"RETIRED mirror still present"* ]]
	[[ "$output" == *"safe to delete"* ]]
	[[ "$output" == *"docs/blueprintx-lessons.md"* ]]
}

# `-f` alone cannot tell a retired generated mirror from a hand-written doc that merely collides
# with the generated name. Telling the reader to delete the second one is the damage this test
# exists to prevent -- the file it names may be the only copy of something nobody can regenerate.
@test "a file at the retired path WITHOUT the generated header says inspect, never delete" {
	lesson "$BX_STORE" "matches-repo" "dotfiles-dev"
	mkdir -p "$REPO/docs"
	printf '# Hand-written notes that merely collide with the generated name\n' \
		>"$REPO/docs/blueprintx-lessons.md"

	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"INSPECT before removing"* ]]
	[[ "$output" != *"safe to delete"* ]]
	[ -f "$REPO/docs/blueprintx-lessons.md" ]
}

@test "the retired path is NEVER deleted — the generator only warns" {
	lesson "$BX_STORE" "matches-repo" "dotfiles-dev"
	mkdir -p "$REPO/docs"
	printf '<!-- GENERATED by generate_lesson_mirrors.sh (make lessons_mirror) — do not hand-edit.\n' \
		>"$REPO/docs/blueprintx-lessons.md"
	printf 'stale pre-#386 mirror\n' >>"$REPO/docs/blueprintx-lessons.md"

	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	[ -f "$REPO/docs/blueprintx-lessons.md" ]
	run grep -qF 'stale pre-#386 mirror' "$REPO/docs/blueprintx-lessons.md"
	[ "$status" -eq 0 ]
}

@test "no retired copy means no warning, and the status is unchanged either way" {
	lesson "$BX_STORE" "matches-repo" "dotfiles-dev"

	run bash "$GEN" "$REPO"
	[ "$status" -eq 0 ]
	[[ "$output" != *"RETIRED mirror"* ]]
}
