#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/lesson_status_backfill.sh (dotfiles-linux-dev#1001).
#
# `gh` is a PATH stub: the unit tests must never reach the real forge. The stub answers
# `gh api [--cache X] repos/<o>/<r>/issues/<n> --jq ...` from a fixture table
# ($TEST_TMP/forge, one "<o>/<r>#<n> <state>" per line, state = what the real --jq prints,
# or "404" / "FAIL") and logs every call to $GH_LOG so the tests can count them.

setup() {
	LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/lesson_status_backfill.sh"
	TEST_TMP="$(mktemp -d)"
	STORE="$TEST_TMP/lessons"
	mkdir -p "$STORE" "$TEST_TMP/bin"
	: >"$TEST_TMP/forge"
	export GH_LOG="$TEST_TMP/gh.log"
	export FORGE="$TEST_TMP/forge"
	: >"$GH_LOG"

	cat >"$TEST_TMP/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$GH_LOG"
[ "$1" = "api" ] || exit 1
shift
[ "$1" = "--cache" ] && shift 2
path="$1"
case "$path" in
rate_limit) echo 1000; exit 0 ;;
repos/*/issues/*)
	repo="${path#repos/}"; repo="${repo%/issues/*}"; n="${path##*/}"
	state="$(awk -v k="$repo#$n" '$1 == k { print $2 }' "$FORGE")"
	case "$state" in
	"") echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
	FAIL) echo "gh: HTTP 502" >&2; exit 1 ;;
	*) echo "$state" ;;
	esac
	;;
*) exit 1 ;;
esac
STUB
	chmod +x "$TEST_TMP/bin/gh"
}

teardown() {
	rm -rf "$TEST_TMP"
}

forge() { printf '%s %s\n' "$1" "$2" >>"$FORGE"; }

# lesson NAME BODY — a lesson file with the given body lines.
lesson() {
	printf '%b\n' "$2" >"$STORE/$1"
}

run_backfill() {
	run env PATH="$TEST_TMP/bin:$PATH" bash "$LIB" --default-repo o/r "$@" "$STORE"
}

# every forge call except the rate_limit probes.
issue_calls() { grep -c 'issues/' "$GH_LOG" || true; }

@test "a PR cited only in prose that merged is delivered and the PR line names it" {
	forge o/r#7 pr-merged
	lesson a.md '# A\n\n**Lesson:** shipped in #7.\n\n**PR:** —\n\n**Origin:** o'
	run_backfill --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"a.md"*"body"*"delivered"* ]]
	grep -q '^\*\*Status:\*\* delivered — o/r#7$' "$STORE/a.md"
	grep -q '^\*\*PR:\*\* o/r#7$' "$STORE/a.md"
}

@test "a PR ref on the PR line: delivered, placeholder PR value replaced by the merged PR" {
	forge o/r#7 pr-merged
	lesson a.md '# A\n\n**Lesson:** x\n\n**PR:** none yet (#7)\n\n**Origin:** o'
	run_backfill --apply
	grep -q '^\*\*Status:\*\* delivered — o/r#7' "$STORE/a.md"
	# a real PR value is never clobbered
	grep -q '^\*\*PR:\*\* none yet (#7)' "$STORE/a.md"
}

@test "an empty PR line value is replaced by the merged PR" {
	forge o/r#7 pr-merged
	lesson a.md '# A\n\n**Status:** queued — see #7\n**PR:** —\n'
	run_backfill --apply
	grep -q '^\*\*PR:\*\* o/r#7$' "$STORE/a.md"
	{ echo "# DBG $(od -c "$STORE/a.md" | head -8)"; } >&3
	grep -q '^\*\*Status:\*\* delivered — o/r#7 (was: queued — see #7)$' "$STORE/a.md"
}

@test "a missing PR line is added when a PR merged" {
	forge o/r#7 pr-merged
	lesson a.md '# A\n\n**Status:** tracked — o/r#7'
	run_backfill --apply
	grep -q '^\*\*PR:\*\* o/r#7$' "$STORE/a.md"
}

@test "an issue closed as completed is delivered, with no PR line invented" {
	forge o/r#8 issue-completed
	lesson a.md '# A\n\n**Status:** tracked — o/r#8'
	run_backfill --apply
	grep -q '^\*\*Status:\*\* delivered — o/r#8' "$STORE/a.md"
	run grep -c 'PR:' "$STORE/a.md"
	[ "$output" = "0" ]
}

@test "a still-open issue is tracked" {
	forge o/r#9 issue-open
	lesson a.md '# A\n\n**Status:** queued — see o/r#9'
	run_backfill --apply
	[[ "$output" == *"tracked"* ]]
	grep -q '^\*\*Status:\*\* tracked — o/r#9 (was: queued' "$STORE/a.md"
}

@test "a Status already tracked with an open issue is unchanged, file untouched" {
	forge o/r#9 issue-open
	lesson a.md '# A\n\n**Status:** tracked — o/r#9'
	cp "$STORE/a.md" "$TEST_TMP/a.before"
	run_backfill --apply
	[[ "$output" == *"unchanged=1"* ]]
	cmp "$STORE/a.md" "$TEST_TMP/a.before"
}

@test "a lesson with no Status gets one added" {
	forge o/r#9 issue-open
	lesson a.md '# A\n\n- **Tier:** t\n- **Origin:** x\n\nSee #9 for the work.'
	run_backfill --apply
	tail -n 2 "$STORE/a.md" | grep -q '^- \*\*Status:\*\* tracked — o/r#9$'
}

@test "no ref: left untouched and reported" {
	lesson a.md '# A\n\n**Status:** queued — no issue\n'
	cp "$STORE/a.md" "$TEST_TMP/a.before"
	run_backfill --apply
	[[ "$output" == *"left: no issue/PR ref"* ]]
	[[ "$output" == *"left-for-human=1"* ]]
	cmp "$STORE/a.md" "$TEST_TMP/a.before"
}

@test "an unreadable ref fails closed: left untouched" {
	forge o/r#9 FAIL
	lesson a.md '# A\n\n**Status:** tracked — o/r#9'
	cp "$STORE/a.md" "$TEST_TMP/a.before"
	run_backfill --apply
	[[ "$output" == *"left: unreadable ref o/r#9"* ]]
	cmp "$STORE/a.md" "$TEST_TMP/a.before"
}

@test "a ref on a disposition line that does not exist is left, not guessed" {
	lesson a.md '# A\n\n**Status:** tracked — o/r#404'
	run_backfill
	[[ "$output" == *"left: ref o/r#404 does not exist"* ]]
}

@test "closed as not_planned is left for a human" {
	forge o/r#9 issue-notplanned
	lesson a.md '# A\n\n**Status:** tracked — o/r#9'
	run_backfill --apply
	[[ "$output" == *"left-for-human=1"* ]]
	grep -q 'tracked — o/r#9$' "$STORE/a.md"
}

@test "open and delivered refs mixed are ambiguous: left" {
	forge o/r#1 issue-open
	forge o/r#2 pr-merged
	lesson a.md '# A\n\n**Status:** tracked — o/r#1\n**PR:** o/r#2'
	run_backfill
	[[ "$output" == *"left: ambiguous"* ]]
}

@test "delivered, advisory and superseded are never overwritten and cost no forge call" {
	forge o/r#5 issue-open
	lesson d.md '# D\n\n**Status:** delivered — pre-PR (abc1234)\nSee #5'
	lesson v.md '# V\n\n**Status:** `advisory` — judgment\nSee #5'
	lesson s.md '# S\n\n**Status:** superseded — newer rule\nSee #5'
	cp -r "$STORE" "$TEST_TMP/before"
	run_backfill --apply
	[[ "$output" == *"kept=3"* ]]
	[ "$(issue_calls)" = "0" ]
	diff -r "$STORE" "$TEST_TMP/before"
}

@test "a ref on a disposition line wins over prose refs" {
	forge o/r#1 issue-open
	forge o/r#2 pr-merged
	lesson a.md '# A\n\n**Status:** tracked — o/r#1\n\nFixed an example in #2.'
	run_backfill
	[[ "$output" == *"meta"*"o/r#1"*"unchanged"* ]]
	[ "$(issue_calls)" = "1" ]
}

@test "the Origin line is not evidence a fix landed" {
	forge o/r#3 issue-completed
	lesson a.md '# A\n\n**Origin:** o (issue o/r#3)\n'
	run_backfill
	[[ "$output" == *"left: no issue/PR ref"* ]]
	[ "$(issue_calls)" = "0" ]
}

@test "a prose-only lesson quoting many refs cannot be attributed" {
	lesson a.md '# A\n\nSeen in #1 #2 #3 #4 #5 #6 #7.\n'
	run_backfill
	[[ "$output" == *"cannot attribute"* ]]
	[ "$(issue_calls)" = "0" ]
}

@test "a bare ref resolves to the default repo, repo#N to the owner, owner/repo#N as is" {
	forge o/r#1 issue-open
	forge guilhermegor/other#2 issue-open
	forge x/y#3 issue-open
	lesson a.md '# A\n\n**Issue:** #1, other#2, x/y#3, https://github.com/x/y/pull/3'
	run_backfill
	[[ "$output" == *"guilhermegor/other#2"* ]]
	[[ "$output" == *"o/r#1"*"x/y#3"* ]]
	[ "$(issue_calls)" = "3" ]
}

@test "forge answers are cached per ref across lessons" {
	forge o/r#1 issue-open
	lesson a.md '# A\n\n**Issue:** #1'
	lesson b.md '# B\n\n**Issue:** #1'
	lesson c.md '# C\n\n**Issue:** o/r#1'
	run_backfill
	[ "$(issue_calls)" = "1" ]
	[[ "$output" == *"forge_calls=1"* ]]
}

@test "a dry run writes nothing" {
	forge o/r#7 pr-merged
	lesson a.md '# A\n\n**Status:** tracked — o/r#7\n**PR:** —'
	cp -r "$STORE" "$TEST_TMP/before"
	run_backfill
	[[ "$output" == *"mode=dry-run"* ]]
	[[ "$output" == *"delivered=1"* ]]
	diff -r "$STORE" "$TEST_TMP/before"
}

@test "apply leaves no temp file behind and keeps the file mode" {
	forge o/r#7 pr-merged
	lesson a.md '# A\n\n**Status:** tracked — o/r#7\n**PR:** —'
	chmod 640 "$STORE/a.md"
	run_backfill --apply
	[ "$(stat -c %a "$STORE/a.md")" = "640" ]
	[ -z "$(find "$STORE" -name '.lesson-backfill.*')" ]
}

@test "the call ceiling fails closed instead of spending more" {
	forge o/r#1 issue-open
	forge o/r#2 issue-open
	lesson a.md '# A\n\n**Issue:** #1'
	lesson b.md '# B\n\n**Issue:** #2'
	run env PATH="$TEST_TMP/bin:$PATH" LESSON_BACKFILL_MAX_CALLS=1 bash "$LIB" --default-repo o/r "$STORE"
	[[ "$output" == *"left-for-human=1"* ]]
	[ "$(issue_calls)" = "1" ]
}

@test "a store with no derivable default repo is refused" {
	mkdir "$TEST_TMP/lessons-other"
	run env PATH="$TEST_TMP/bin:$PATH" bash "$LIB" "$TEST_TMP/lessons-other"
	[ "$status" -eq 2 ]
}

@test "sourcing the library defines functions and prints nothing" {
	run bash -c "source '$LIB' && type lesson_has_ref >/dev/null"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "lesson_has_ref sees #N, pull/N, repo#N and a github URL, not an anchor or entity" {
	printf 'x #12\n' >"$TEST_TMP/1.md"
	printf 'x pull/12\n' >"$TEST_TMP/2.md"
	printf 'x blueprintx#12\n' >"$TEST_TMP/3.md"
	printf 'x https://github.com/a/b/issues/12\n' >"$TEST_TMP/4.md"
	printf 'x &#123; and # Heading and #abc\n' >"$TEST_TMP/5.md"
	for i in 1 2 3 4; do
		run bash -c "source '$LIB' && lesson_has_ref '$TEST_TMP/$i.md'"
		[ "$status" -eq 0 ]
	done
	run bash -c "source '$LIB' && lesson_has_ref '$TEST_TMP/5.md'"
	[ "$status" -ne 0 ]
}
