#!/bin/bash
# Regenerates the current repo's git-ignored lesson mirrors under .specs/_lessons/
# from the global lesson stores (dotfiles-dev#386).
#
# Why this exists: a mirror is a DERIVED, machine-checked index of a lesson store
# that lives outside the repo — it should never be typed by hand. Before this
# script, a lesson needed three hand-writes (the store file, the store's README
# index, and the mirror) and the third one drifted: measured 2026-09-14, 19 of 43
# `Origin: dotfiles-dev` lessons were missing from the hand-maintained mirror.
# Regenerating removes that drift class instead of detecting it.
#
# Usage:  generate_lesson_mirrors.sh [repo-root]   (default: $PWD)
#
# For each store in LESSON_STORES (lib/lesson_mirrors.sh) that expects a mirror
# in this repo (mirror_expected_for_repo() — same predicate session_capture_audit.sh's
# check_mirrors() uses, so the two can never independently drift), collect every
# lesson whose **Origin:** line names this repo (lesson_originates_in_repo(), also
# shared) and write them, sorted by filename, to that store's mirror file. A store
# whose registered directory is absent falls back to its declared legacy directory
# (resolve_store_dir(), lib/lesson_mirrors.sh) before being treated as truly missing
# (dotfiles-dev#536 review, PR #546) — see generate_store_mirror() for why.
#
# Owner-approved (2026-09-14): this MAY create `.specs/` from scratch in a repo
# that has none — most active repos don't (dotfiles-dev#386). It creates only the
# `_lessons/` directory the mirror needs via `mkdir -p`, deliberately NOT a
# `.specs/CLAUDE.md` contract file: that file documents the feature-spec layout
# (spec.md/design.md/plan.md), which this repo has not adopted just because it
# now has a mirror.
set -uo pipefail

# shellcheck source=lesson_mirrors.sh
source "$(dirname "${BASH_SOURCE[0]}")/lesson_mirrors.sh"

# Renders one lesson's mirror section from its own fields — first line only per
# field (a wrapped multi-line Lesson/Why is truncated to its first line; the full
# text is one click away in the source file, which is the point of a mirror).
render_entry() {
	local file="$1" name title tier lesson why origin
	name="$(basename "$file")"
	title="$(sed -n '1s/^#\+[[:space:]]*//p' "$file")"
	tier="$(grep -m1 -E '^[[:space:]]*([-*][[:space:]]+)?\*\*(Tier|Area):\*\*' "$file" |
		sed -E 's/^[[:space:]]*([-*][[:space:]]+)?\*\*(Tier|Area):\*\*[[:space:]]*//')"
	lesson="$(grep -m1 -E '^[[:space:]]*([-*][[:space:]]+)?\*\*Lesson:\*\*' "$file" |
		sed -E 's/^[[:space:]]*([-*][[:space:]]+)?\*\*Lesson:\*\*[[:space:]]*//')"
	why="$(grep -m1 -E '^[[:space:]]*([-*][[:space:]]+)?\*\*Why:\*\*' "$file" |
		sed -E 's/^[[:space:]]*([-*][[:space:]]+)?\*\*Why:\*\*[[:space:]]*//')"
	origin="$(grep -m1 -E '^[[:space:]]*([-*][[:space:]]+)?\*\*Origin:\*\*' "$file" |
		sed -E 's/^[[:space:]]*([-*][[:space:]]+)?\*\*Origin:\*\*[[:space:]]*//')"

	printf '## %s\n\n' "${title:-$name}"
	printf -- '- **Source:** `%s`\n' "$name"
	[ -n "$tier" ] && printf -- '- **Tier/Area:** %s\n' "$tier"
	[ -n "$lesson" ] && printf -- '- **Lesson:** %s\n' "$lesson"
	[ -n "$why" ] && printf -- '- **Why:** %s\n' "$why"
	[ -n "$origin" ] && printf -- '- **Origin:** %s\n' "$origin"
	printf '\n'
}

# Regenerates one store's mirror for $repo, if this store expects one here.
generate_store_mirror() {
	local cwd="$1" repo="$2" store="$3" mirror_base="$4" target_repo="$5" identity_source="$6" legacy_dir="$7"
	if ! mirror_expected_for_repo "$target_repo" "$repo"; then
		# The "-" sentinel (lessons-other) has no repo to name — nothing to explain.
		# A repo that IS one of the store's declared aliases DOES need explaining: this
		# is the exact case that used to write an empty, authoritative-looking mirror
		# (dotfiles-dev#536) — say why nothing was written instead of writing nothing
		# silently.
		if [ "$target_repo" != "-" ]; then
			printf 'ℹ %s: no mirror for %s (repo identity resolved via %s; declared as one of this store'"'"'s own repos) — no self-mirror\n' \
				"$mirror_base" "$repo" "$identity_source" >&2
		fi
		return 0
	fi

	# A mirror IS expected here, so a missing store directory is a CONFIGURATION
	# ERROR — a registry entry naming a path that isn't there — never "nothing to
	# generate from" (dotfiles-dev#536): `[ -d "$store" ] || return 0` used to sit
	# ahead of the check above and swallow exactly this case silently, indistinguishable
	# from the legitimate "zero lessons yet" mirror it would otherwise write.
	#
	# But "registered path absent" and "renamed-but-not-yet-migrated" are also two
	# different facts a hard failure conflates (PR #546 review): `LESSON_STORES`
	# ships the moment `make ai_clients` runs, while `~/.claude/memory/` is user
	# data with no deploy step at all, so a machine that renamed the registry entry
	# without also moving its directory hits this branch on EVERY repo, every run
	# — `make lessons_mirror` never gets to write anything again until a human
	# notices. resolve_store_dir() tries the declared legacy directory first;
	# only when NEITHER exists is this a real configuration error.
	local resolved effective_store dir_source
	if resolved="$(resolve_store_dir "$store" "$legacy_dir")"; then
		effective_store="${resolved%%$'\t'*}"
		dir_source="${resolved##*$'\t'}"
	else
		printf '✗ %s: registered store %s does not exist — cannot generate a mirror for %s\n' \
			"$mirror_base" "$store" "$repo" >&2
		return 1
	fi
	if [ "$dir_source" = "legacy" ]; then
		# Advisory only — this never auto-`mv`s user data from inside a mirror
		# generator (PR #546 review: "a bigger promise than this seam should make").
		printf 'ℹ %s: %s not found — reading the legacy path %s instead (migrate with: mv %s %s)\n' \
			"$mirror_base" "$store" "$effective_store" "$effective_store" "$store" >&2
	fi
	store="$effective_store"

	local -a matches=()
	local file
	for file in "$store"/*.md; do
		[ -e "$file" ] || continue
		[ "$(basename "$file")" = "README.md" ] && continue
		lesson_originates_in_repo "$file" "$repo" && matches+=("$file")
	done
	# Deterministic order (filename) — required for the file to be idempotent
	# across regenerations regardless of the store's own directory-listing order.
	if [ "${#matches[@]}" -gt 0 ]; then
		mapfile -t matches < <(printf '%s\n' "${matches[@]}" | sort)
	fi

	local mirror rel
	rel="$(mirror_rel_path "$mirror_base")"
	mirror="$cwd/$rel"
	mkdir -p "$(dirname "$mirror")" || return 1

	{
		printf '<!-- GENERATED by generate_lesson_mirrors.sh (make lessons_mirror) — do not hand-edit.\n'
		printf '     Source: %s -->\n\n' "$store"
		printf '# %s — lessons originating in %s\n\n' "$mirror_base" "$repo"
		printf '## Source files\n\n'
		for file in "${matches[@]}"; do
			printf -- '- `%s`\n' "$(basename "$file")"
		done
		printf '\n'
		for file in "${matches[@]}"; do
			render_entry "$file"
		done
	} >"$mirror"

	# The mirror moved to .specs/_lessons/ in dotfiles-dev#386 and nothing cleaned up behind it,
	# so repos still carry a pre-move copy that no longer regenerates -- a stale doc a reader can
	# open and trust. Warn, never delete: this may run from a hook, and a generator that removes
	# files would also remove a legitimately hand-written docs/<base>.md that merely collides.
	# ⚠️ Advisory ONLY -- the exit status stays untouched. Failing the run over a leftover would
	# break the unrelated flows this is called from.
	local retired
	retired="$cwd/$(retired_mirror_rel_path "$mirror_base")"
	# `-f` proves a file EXISTS at the retired path, never that it is a retired mirror. The
	# generated header is the one thing that tells the two apart, so read it instead of guessing
	# from the name -- a hand-written docs/<base>.md that merely collides must never be reported
	# as safe to delete. Absence of the marker is reported as "cannot confirm", not as proof the
	# file is hand-written: a mirror generated before the header existed would also lack it.
	if [ -f "$retired" ]; then
		if head -1 "$retired" 2>/dev/null | grep -q 'GENERATED by generate_lesson_mirrors.sh'; then
			printf '⚠ RETIRED mirror still present: %s\n' "$(retired_mirror_rel_path "$mirror_base")" >&2
			printf '  (pre-#386 path, carries the generated header; nothing regenerates it — safe to delete)\n' >&2
		else
			printf '⚠ File at the retired mirror path: %s\n' "$(retired_mirror_rel_path "$mirror_base")" >&2
			printf '  (no generated header — may be hand-written; INSPECT before removing)\n' >&2
		fi
	fi
}

main() {
	local cwd repo identity identity_source entry store mirror_base _kind target_repo legacy_dir
	# This file runs under `set -uo pipefail`, NOT `-e`, so a failed `cd` would
	# leave $cwd empty and every mirror path would be built under `/.specs/`
	# — writing outside the repo, or failing confusingly. Reject it here.
	cwd="$(cd -- "${1:-$PWD}" && pwd)" || {
		printf 'Invalid repository root: %s\n' "${1:-$PWD}" >&2
		return 1
	}

	# repo="$(basename "$cwd")" alone made a DIRECTORY NAME production configuration
	# (dotfiles-dev#536) — prefer the `origin` remote, basename only as a fallback,
	# and say which one was used so a mismatch is visible rather than silent.
	identity="$(resolve_repo_identity "$cwd")" || {
		printf 'Could not resolve repo identity for %s (no origin remote, no usable basename) — writing no mirrors, never an empty one.\n' "$cwd" >&2
		return 1
	}
	repo="${identity%%$'\t'*}"
	identity_source="${identity##*$'\t'}"
	if [ -z "$repo" ]; then
		printf 'Repo identity unresolved for %s — writing no mirrors, never an empty one.\n' "$cwd" >&2
		return 1
	fi
	printf 'Resolved repo identity: %s (via %s)\n' "$repo" "$identity_source" >&2

	for entry in "${LESSON_STORES[@]}"; do
		IFS='|' read -r store mirror_base _kind target_repo legacy_dir <<<"$entry"
		# Propagate: without this the loop swallows a failed mkdir/redirect and
		# the LAST store's status becomes the exit code, so `make lessons_mirror`
		# reports success having written no mirror (PR #388 review).
		generate_store_mirror "$cwd" "$repo" "$store" "$mirror_base" "$target_repo" "$identity_source" "$legacy_dir" || return 1
	done
}

main "$@"
