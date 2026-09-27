#!/bin/bash
# Shared lesson-mirror definitions (dotfiles-dev#386) — sourced by BOTH
# session_capture_audit.sh (the checker) and generate_lesson_mirrors.sh (the
# generator), so the store list, the mirror's on-disk path, and the "did this
# lesson originate in this repo?" predicate live in exactly ONE place. Two
# hand-written copies of the same join rule is the drift class this file
# closes — a change here changes what both the checker and the generator
# agree on, together, always.
#
# Kept dependency-free and side-effect-free (only defines vars/functions, no
# I/O, no `set -e`) so sourcing it can never fail a caller that must never
# fail a session (session_capture_audit.sh's own contract).

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# All generalizable-lessons stores, each as "dir|mirror-basename|kind|target-repo".
# target-repo is the store's backport target: a lesson that ORIGINATED in that
# repo needs no mirror there (the mirror would be redundant), so
# mirror_expected_for_repo() below skips it. target-repo "-" (lessons-other,
# dotfiles-dev#356) is a sentinel, not a repo name: that store has no distinct
# backport target at all, so it never gets a mirror anywhere.
# Used by every file that sources this lib (session_capture_audit.sh,
# generate_lesson_mirrors.sh) — shellcheck can't see those callers.
# shellcheck disable=SC2034
LESSON_STORES=(
	"$CLAUDE_DIR/memory/lessons|blueprintx-lessons|blueprintx|blueprintx"
	"$CLAUDE_DIR/memory/lessons-dotfiles|dotfiles-dev-lessons|dotfiles|dotfiles-dev"
	"$CLAUDE_DIR/memory/lessons-other|lessons-other|other|-"
)

# A store's mirror path, relative to a repo's root — the ONE construction site
# (dotfiles-dev#386) instead of the "$cwd/docs/$mirror_base.md" string that used
# to be hand-typed in five separate files. Lives under .specs/_lessons/ (not
# docs/): the mirror is a derived, git-ignored working artifact, not shipped
# documentation — see .specs/CLAUDE.md. The leading underscore on `_lessons`
# follows the existing "not a work unit" marker convention (`.specs/`'s top
# level otherwise namespaces features/projects; a lessons mirror is neither),
# and the name describes the CONTENT (lessons), not the mechanism (a mirror) —
# this very change turns it from hand-written to generated, so a name built on
# "mirror" would describe a property the change removes.
mirror_rel_path() {
	local mirror_base="$1"
	printf '.specs/_lessons/%s.md\n' "$mirror_base"
}

# The PRE-#386 mirror location. Nothing WRITES here -- this exists so the generator can warn that
# a stale copy is still sitting in a repo, because the path moved and nothing cleaned up behind
# it. Defined next to mirror_rel_path so the live path and the retired one cannot drift apart.
retired_mirror_rel_path() {
	local mirror_base="$1"
	printf 'docs/%s.md\n' "$mirror_base"
}

# Absolute mirror path for repo checkout $cwd.
mirror_path() {
	local cwd="$1" mirror_base="$2"
	printf '%s/%s\n' "$cwd" "$(mirror_rel_path "$mirror_base")"
}

# Does a store need a mirror inside $repo at all? Same-repo-as-target and the
# "-" sentinel are both "no distinct backport target" cases — never expect a
# mirror either way (dotfiles-dev#356, #386).
mirror_expected_for_repo() {
	local target_repo="$1" repo="$2"
	[ "$target_repo" = "-" ] && return 1
	[ "$target_repo" = "$repo" ] && return 1
	return 0
}

# Does $file (a lesson in some store) name $repo on its **Origin:** line? The
# ONE predicate both check_mirrors() and the generator use to decide which
# lessons belong in a given repo's mirror (bullet optional: the stores use
# both "- **Origin:**" and a bare "**Origin:**").
#
# ⚠️ Compares the FIRST TOKEN after the marker literally — never a `\b${repo}\b`
# search over the whole line. `-` is a non-word character, so `\bdotfiles-dev\b`
# matches inside `not-dotfiles-dev`, and every repo name here contains a dash.
# Measured (PR #388 review): that regex accepted `**Origin:** not-dotfiles-dev`
# for repo `dotfiles-dev`, which would put an unrelated lesson in the mirror AND
# make the audit accept the same false association — a wrong answer both sides
# agree on is the worst shape, since the cross-check cannot catch it.
#
# ⚠️ A literal whole-field compare is ALSO wrong, and was measured so: it drops 8
# real lessons out of 43, because the stores use two shapes a single value cannot
# express —
#   - **Origin:** blueprintx / dotfiles-dev (2026-08-17)   ← two repos, both true
#   - **Origin:** dotfiles-dev#344 (closed not-planned)    ← repo plus issue ref
# So the value is cut at the first `(`/`,`/`.`/`—` (everything after is prose),
# split on `/`, reduced to each segment's first word, and stripped of a `#NNN`
# suffix. Each resulting token is then compared literally.
#
# That accepts both shapes above and still rejects `not-dotfiles-dev`, which is
# the whole point. It also correctly declines `dotfiles-dev#126 / PR #127, from
# blueprintx #180` for repo `blueprintx`: cut at the comma, blueprintx is cited
# as the SOURCE of the idea, not the origin repo — the old regex matched it.
lesson_originates_in_repo() {
	local file="$1" repo="$2" value segment token
	value="$(sed -nE 's/^[[:space:]]*([-*][[:space:]]+)?\*\*[Oo]rigin:\*\*[[:space:]]*(.*)/\2/p' \
		"$file" 2>/dev/null | head -n1)"
	[ -n "$value" ] || return 1
	value="${value%%(*}"
	value="${value%%,*}"
	value="${value%%.*}"
	value="${value%%—*}"

	local IFS='/'
	for segment in $value; do
		token="${segment#"${segment%%[![:space:]]*}"}"   # ltrim
		token="${token%%[[:space:]]*}"                    # first word only
		token="${token%%#*}"                              # drop a #NNN issue ref
		[ "${token,,}" = "${repo,,}" ] && return 0
	done
	return 1
}
