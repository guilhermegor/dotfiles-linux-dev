#!/bin/bash
# Shared lesson-mirror definitions (dotfiles-linux-dev#386) — sourced by BOTH
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

# All generalizable-lessons stores, each as
# "dir|mirror-basename|kind|target-repos|legacy-dir". target-repos is the store's
# backport target SET: a comma-separated list of every repo that IS this store's own
# origin (a lesson originating in any one of them needs no mirror there — the mirror
# would be redundant), so mirror_expected_for_repo() below skips it for ALL of them.
# target-repos "-" (lessons-other, dotfiles-linux-dev#356) is a sentinel, not a repo name:
# that store has no distinct backport target at all, so it never gets a mirror
# anywhere.
#
# The set is declared explicitly, never guessed from a `dotfiles*` prefix
# (dotfiles-linux-dev#536): the toolchain repo has already been renamed once
# (dotfiles-dev → dotfiles-linux-dev on GitHub, while local checkouts kept the old
# directory name) with dotfiles-macos-dev/dotfiles-linux-prod planned, and a name
# guessed from a pattern would silently include or exclude the wrong repo the moment
# naming drifts again — the same house style as an explicit, named exemption (e.g.
# py-standards.md's stpstone Snyk exemption) over a pattern match.
#
# legacy-dir (optional, "" when a store has never been renamed) is this SAME
# reasoning applied to the store's own directory, not just the repo identifier it
# resolves (dotfiles-linux-dev#536 review, PR #546): `LESSON_STORES` ships via
# `make ai_clients`, but `~/.claude/memory/` is user data with no deploy step at
# all — a machine that still holds the pre-rename `lessons-dotfiles/` directory
# gets the renamed CODE immediately and the renamed DATA never, and nothing here
# migrates it for that machine. resolve_store_dir() below falls back to this path
# read-only (never auto-`mv`s user data) and says so, rather than reporting the
# store as absent.
#
# Used by every file that sources this lib (session_capture_audit.sh,
# generate_lesson_mirrors.sh) — shellcheck can't see those callers.
# shellcheck disable=SC2034
LESSON_STORES=(
	"$CLAUDE_DIR/memory/lessons|blueprintx-lessons|blueprintx|blueprintx|"
	"$CLAUDE_DIR/memory/lessons-claude-toolchain|claude-toolchain-lessons|dotfiles|dotfiles-dev,dotfiles-linux-dev,dotfiles-macos-dev,dotfiles-linux-prod|$CLAUDE_DIR/memory/lessons-dotfiles"
	"$CLAUDE_DIR/memory/lessons-other|lessons-other|other|-|"
)

# resolve_store_dir STORE LEGACY
# Prints "<effective-dir>\t<current|legacy>" — the directory a caller should
# actually read this store from right now. Prefers STORE; falls back to LEGACY
# only when STORE doesn't exist AND LEGACY is declared (non-empty) and does exist.
# Read-only: never moves or copies anything, so a caller must still print its own
# "not yet migrated" diagnostic when the source comes back "legacy" — this
# function only answers "which directory", never "is this fine to leave as is".
# Returns non-zero with empty output when neither directory exists.
resolve_store_dir() {
	local store="$1" legacy="$2"
	if [ -d "$store" ]; then
		printf '%s\tcurrent\n' "$store"
		return 0
	fi
	if [ -n "$legacy" ] && [ -d "$legacy" ]; then
		printf '%s\tlegacy\n' "$legacy"
		return 0
	fi
	return 1
}

# A store's mirror path, relative to a repo's root — the ONE construction site
# (dotfiles-linux-dev#386) instead of the "$cwd/docs/$mirror_base.md" string that used
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

# resolve_repo_identity CWD
# Prints "<repo-name>\t<source>" — the bare repo name plus which signal produced it,
# so a caller can say which one was used (dotfiles-linux-dev#536). Prefers the `origin`
# remote (owner/name → the name half, works for both SSH and HTTPS forms), falling
# back to the directory basename only when there is no parseable origin.
#
# `repo="$(basename "$cwd")"` alone made a DIRECTORY NAME production configuration:
# this very toolchain repo was renamed dotfiles-dev → dotfiles-linux-dev on GitHub
# while every existing local checkout kept the old directory name, and the reverse
# (a fresh clone picking up the new name) is one `git clone` away.
#
# Returns non-zero with EMPTY output only when NEITHER signal resolves to a
# non-empty name (no origin remote AND no usable basename) — callers must treat
# that as UNRESOLVED, never as "no repo", and must write nothing rather than guess
# (scope 4: an unresolved identity must never produce an empty mirror that reads as
# a verdict).
resolve_repo_identity() {
	local cwd="$1" url name
	url="$(git -C "$cwd" remote get-url origin 2>/dev/null)"
	if [ -n "$url" ]; then
		name="${url%.git}"
		name="${name##*/}"
		if [ -n "$name" ]; then
			printf '%s\tremote\n' "$name"
			return 0
		fi
	fi
	name="$(basename -- "$cwd" 2>/dev/null)"
	if [ -n "$name" ] && [ "$name" != "/" ]; then
		printf '%s\tbasename\n' "$name"
		return 0
	fi
	return 1
}

# resolve_repo_identity_only CWD
# Convenience wrapper over resolve_repo_identity() for callers that only need the
# bare repo name, not which signal produced it. Same unresolved contract: non-zero
# with empty output, never a guess.
resolve_repo_identity_only() {
	local identity
	identity="$(resolve_repo_identity "$1")" || return 1
	printf '%s\n' "${identity%%$'\t'*}"
}

# repo_citation_regex REPO
# An ERE alternation of REPO's full declared alias group (repo_alias_group), for
# matching a `<repo>#<issue>` citation written under ANY of that repo's names — the
# same alias-set reasoning as lesson_originates_in_repo, applied to the completeness
# table's PR-citation check (dotfiles-linux-dev#536): a citation written as
# `dotfiles-linux-dev#42` before the rename must still count as accounted for when the
# CURRENT identity resolves to `dotfiles-linux-dev`.
repo_citation_regex() {
	local repo="$1" alias joined=""
	while IFS= read -r alias; do
		[ -n "$alias" ] || continue
		if [ -z "$joined" ]; then joined="$alias"; else joined="$joined|$alias"; fi
	done < <(repo_alias_group "$repo")
	printf '%s\n' "$joined"
}

# repo_alias_group REPO
# Newline-separated list of REPO's declared aliases: the target-repos field of
# whichever LESSON_STORES entry declares REPO among its set, or REPO alone when no
# store declares it. This is the ONE place "which repos are really the same thing"
# is answered — by declaration, never by a `dotfiles*` prefix guess (dotfiles-linux-dev#536).
repo_alias_group() {
	local repo="$1" entry _store _mirror_base _kind target_repos _legacy alias
	for entry in "${LESSON_STORES[@]}"; do
		# The trailing _legacy var is unused here but MUST be captured: `read` with
		# fewer variables than fields folds every extra field into the LAST one,
		# which would silently append "|<legacy-dir>" onto target_repos otherwise.
		IFS='|' read -r _store _mirror_base _kind target_repos _legacy <<<"$entry"
		[ "$target_repos" = "-" ] && continue
		local IFS=','
		for alias in $target_repos; do
			if [ "${alias,,}" = "${repo,,}" ]; then
				printf '%s\n' "$target_repos" | tr ',' '\n'
				return 0
			fi
		done
	done
	printf '%s\n' "$repo"
}

# Does a store need a mirror inside $repo at all? $repo being a MEMBER of the
# store's declared target-repos set (not just an exact single-string match — the
# set may hold several aliases of the same repo, dotfiles-linux-dev#536) and the "-"
# sentinel are both "no distinct backport target" cases — never expect a mirror
# either way (dotfiles-linux-dev#356, #386).
mirror_expected_for_repo() {
	local target_repos="$1" repo="$2" alias
	[ "$target_repos" = "-" ] && return 1
	local IFS=','
	for alias in $target_repos; do
		[ "${alias,,}" = "${repo,,}" ] && return 1
	done
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
#   - **Origin:** dotfiles-linux-dev#344 (closed not-planned)    ← repo plus issue ref
# So the value is cut at the first `(`/`,`/`.`/`—` (everything after is prose),
# split on `/`, reduced to each segment's first word, and stripped of a `#NNN`
# suffix. Each resulting token is then compared literally.
#
# That accepts both shapes above and still rejects `not-dotfiles-dev`, which is
# the whole point. It also correctly declines `dotfiles-linux-dev#126 / PR #127, from
# blueprintx #180` for repo `blueprintx`: cut at the comma, blueprintx is cited
# as the SOURCE of the idea, not the origin repo — the old regex matched it.
#
# $repo is expanded to its full declared alias group (repo_alias_group) before
# comparing — an existing lesson stamped `**Origin:** dotfiles-dev` still resolves
# for a `dotfiles-linux-dev`/`dotfiles-macos-dev`/`dotfiles-linux-prod` checkout
# without touching any of the ~242 lesson files (dotfiles-linux-dev#536 scope 5: the
# matcher accepts the alias set rather than migrating every Origin line — chosen
# because the store is a GLOBAL directory written concurrently by other sessions,
# and a mass rewrite of every file races those writers for no behavioural gain).
lesson_originates_in_repo() {
	local file="$1" repo="$2" value segment token alias
	value="$(sed -nE 's/^[[:space:]]*([-*][[:space:]]+)?\*\*[Oo]rigin:\*\*[[:space:]]*(.*)/\2/p' \
		"$file" 2>/dev/null | head -n1)"
	[ -n "$value" ] || return 1
	value="${value%%(*}"
	value="${value%%,*}"
	value="${value%%.*}"
	value="${value%%—*}"

	local -a aliases=()
	while IFS= read -r alias; do
		[ -n "$alias" ] && aliases+=("$alias")
	done < <(repo_alias_group "$repo")

	local IFS='/'
	for segment in $value; do
		token="${segment#"${segment%%[![:space:]]*}"}"   # ltrim
		token="${token%%[[:space:]]*}"                    # first word only
		token="${token%%#*}"                              # drop a #NNN issue ref
		for alias in "${aliases[@]}"; do
			[ "${token,,}" = "${alias,,}" ] && return 0
		done
	done
	return 1
}
