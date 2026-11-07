#!/bin/bash
# Shared "is this issue body a complete spec?" check (dotfiles-linux-dev#931).
#
# One implementation, two callers: issue_template_guard.sh applies `evaluate_template` at creation,
# and roadmap_unblock.sh applies it when the last blocker closes, to pick Ready (complete) or
# Backlog (not). Never a second copy of the template rules, so the two cannot drift on them. The
# unblock is STRICTER than the guard: on top of the template it requires every section to hold
# text and a closed, non-empty surface block (`spec_incomplete_reasons`), which the guard does not.
#
# Functions (all sourced, none print unless stated):
#   strip_frontmatter_and_comments FILE      prints the template's structural markdown
#   section_has_checklist TEXT HEADER        true when HEADER's section has a `- [ ]` item
#   evaluate_template TEMPLATE BODY LABELS   sets global `missing` (array) of unmet requirements
#   spec_section_filled BODY HEADER          true when HEADER's section has non-comment text
#   spec_surface_nonempty BODY               true when a ```surface block names at least one path
#   spec_incomplete_reasons BODY [TEMPLATE…] prints one reason per line, nothing when complete

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "issue_spec_complete.sh is meant to be sourced, not executed." >&2
	exit 1
fi

# Strip a template's YAML frontmatter and HTML comment blocks, leaving only the structural
# markdown content the required-headers/checklist/lead-line rules read from.
strip_frontmatter_and_comments() {
	awk '
		NR==1 && $0=="---" { fm=1; next }
		fm==1 { if ($0=="---") fm=0; next }
		/<!--/ { incomment=1 }
		incomment==1 { if ($0 ~ /-->/) incomment=0; next }
		{ print }
	' "$1"
}

# _spec_section TEXT HEADER
# Prints the lines of the first `##`/`###` section whose heading TEXT equals HEADER
# (case-insensitive, whole heading: `Scope` does not match `Out of scope`), up to the next heading
# of the same or a higher level (a `###` subsection stays inside its `##` section) or EOF. Headings
# inside fenced code blocks are not headings. Prints nothing, returns 1 when absent. The printed
# section is lowercased: bash folds the text (UTF-8 aware) before awk sees it, because mawk's
# tolower() leaves non-ASCII letters alone and `## Ação` would then never match.
_spec_section() {
	# CR stripped first: bodies edited in GitHub's web UI arrive with CRLF line endings.
	local text="${1//$'\r'/}" header="${2,,}"
	text="${text,,}"
	awk -v want="$header" '
		/^```/ { fence = !fence }
		!fence && /^###?[ \t]/ {
			level = match($0, /[^#]/) - 1
			h = $0; sub(/^#+[ \t]*/, "", h); sub(/[ \t]+$/, "", h)
			if (found && level <= flevel) exit
			if (!found && h == want) { found = 1; flevel = level; next }
		}
		found { print }
		END { exit !found }
	' <<<"$text"
}

# True if $1 (a multi-line block of text) has a `##`/`###` header equal to $2 (case-insensitive,
# whole heading) whose section (up to the next such header, or EOF) contains a `- [ ]`/`- [x]` item.
section_has_checklist() {
	local section
	section="$(_spec_section "$1" "$2")" || return 1
	grep -Eq '^[[:space:]]*[-*][[:space:]]+\[[ xX]\]' <<<"$section"
}

# True when the section under header $2 of body $1 holds any text beyond blank lines and HTML
# comments (an unfilled template placeholder is a comment, so it counts as empty).
spec_section_filled() {
	local section
	section="$(_spec_section "$1" "$2")" || return 1
	# A fenced surface block is its own requirement (spec_surface_nonempty), never section text.
	# Inline `<!-- … -->` goes first (each comment stops at its first `-->`, so prose between two survives), then
	# multi-line comments. A heading line is structure, not text, unless inside a code fence.
	sed -E 's/<!--([^-]|-[^-])*-->//g' <<<"$section" \
		| awk '/^```surface[ \t]*$/ { s=1; next } s { if ($0 ~ /^```/) s=0; next }
			/<!--/ { c=1 } c { if ($0 ~ /-->/) c=0; next }
			/^```/ { f=!f } !f && /^#+[ \t]/ { next } { print }' \
		| grep -q '[^[:space:]]'
}

# True when body $1 carries a fenced ```surface block with at least one path line (not blank, not
# a `#` placeholder), the same convention dispatch_plan.py's SURFACE_LABEL_PREFIX reads.
spec_surface_nonempty() {
	# Only a CLOSED fence counts: dispatch_plan.py reads an unterminated block as undeclared.
	awk '
		/^```surface[[:space:]]*$/ { in_block=1; found=0; next }
		in_block && /^```/ { in_block=0; if (found) ok=1; next }
		in_block && $0 !~ /^[[:space:]]*(#.*)?$/ { found=1 }
		END { exit !ok }
	' <<<"${1//$'\r'/}"
}

# Populate the global `missing` array with every requirement of $1 (a template file) that $2 (the
# body) fails to satisfy, given $3 (newline-separated labels positively known on this command).
evaluate_template() {
	local template="$1" body="$2" labels="$3"
	local stripped first_tmpl_line first_body_line line header literal cond
	missing=()

	stripped="$(strip_frontmatter_and_comments "$template")"

	first_tmpl_line="$(grep -m1 -v '^[[:space:]]*$' <<<"$stripped")"
	if [[ -n "$first_tmpl_line" ]]; then
		first_body_line="$(grep -m1 -v '^[[:space:]]*$' <<<"$body")"
		if [[ "$first_tmpl_line" == '**'* && "$first_body_line" != '**'* ]]; then
			missing+=("a bold first line, like: $first_tmpl_line")
		fi
		if [[ "$first_tmpl_line" == *'·'* && "$first_body_line" != *'·'* ]]; then
			missing+=("a '·'-separated first line, like: $first_tmpl_line")
		fi
	fi

	while IFS= read -r line; do
		header="$(sed -E 's/^#+[[:space:]]*//; s/[[:space:]]+$//' <<<"$line")"
		[[ -n "$header" ]] || continue
		if ! grep -qiF -- "$header" <<<"$body"; then
			missing+=("$header")
			continue
		fi
		if section_has_checklist "$stripped" "$header" && ! section_has_checklist "$body" "$header"; then
			missing+=("$header (needs at least one - [ ] item)")
		fi
	done < <(grep -E '^#{2,3}[[:space:]]' <<<"$stripped")

	while IFS= read -r line; do
		[[ "$line" =~ issue-template-guard:[[:space:]]*require[[:space:]]+\"([^\"]+)\"([[:space:]]+if-label[[:space:]]+([^[:space:]]+))? ]] || continue
		literal="${BASH_REMATCH[1]}"
		cond="${BASH_REMATCH[3]:-}"
		if [[ -n "$cond" ]]; then
			grep -qxF -- "$cond" <<<"$labels" || continue   # label not positively known → fail open
		fi
		grep -qiF -- "$literal" <<<"$body" || missing+=("$literal")
	done < <(grep -E 'issue-template-guard:' "$template")
}

# spec_incomplete_reasons BODY [TEMPLATE_FILE…]
# Prints why BODY is not a complete spec, one reason per line, or nothing when it is complete.
# Complete = some template is fully satisfied (evaluate_template) with every non-surface section
# actually filled, AND a non-empty surface block. With no template (the repo ships none) the
# one required section is `What / Why`, the section every issue skeleton here starts with.
# SPEC_LABELS (newline-separated issue labels, optional) enables a template's `if-label` rules.
# The best template (fewest reasons) is the one reported, same as the guard's "closest template".
spec_incomplete_reasons() {
	local body="$1"; shift
	local -a templates=("$@") best=() reasons=()
	local best_n=-1 template fallback="" line header stripped
	# A template with no `##`/`###` heading (blank or free-form) requires nothing, so on its own it
	# would let any body with a surface block win "fewest reasons". Without a single sectioned
	# template, the `What / Why` skeleton applies, exactly as when the repo ships none.
	local t sectioned=0
	for t in "${templates[@]+"${templates[@]}"}"; do
		strip_frontmatter_and_comments "$t" | grep -qE '^#{2,3}[[:space:]]' && sectioned=1
	done
	if ((sectioned == 0)); then
		templates=()
		fallback="$(mktemp)" || { echo "no temp file for the fallback template" >&2; return 1; }
		printf '## What / Why\n' >"$fallback"
		templates=("$fallback")
	fi
	for template in "${templates[@]}"; do
		evaluate_template "$template" "$body" "${SPEC_LABELS:-}"
		reasons=("${missing[@]+"${missing[@]}"}")
		stripped="$(strip_frontmatter_and_comments "$template")"
		while IFS= read -r line; do
			header="$(sed -E 's/^#+[[:space:]]*//; s/[[:space:]]+$//' <<<"$line")"
			[[ -n "$header" ]] || continue
			# The section holding the ```surface fence is checked by spec_surface_nonempty.
			_spec_section "$stripped" "$header" | grep -q '^```surface' && continue
			# evaluate_template matched the header text anywhere; the heading line itself is
			# required here, and its section must hold text.
			if ! _spec_section "$body" "$header" >/dev/null; then
				printf '%s\n' "${reasons[@]+"${reasons[@]}"}" \
					| grep -qxF -e "$header" -e "$header (needs at least one - [ ] item)" \
					|| reasons+=("$header")
			elif ! spec_section_filled "$body" "$header"; then
				reasons+=("empty $header")
			fi
		done < <(grep -E '^#{2,3}[[:space:]]' <<<"$stripped")
		spec_surface_nonempty "$body" || reasons+=("no surface block")
		if ((best_n == -1 || ${#reasons[@]} < best_n)); then
			best_n=${#reasons[@]}
			best=("${reasons[@]+"${reasons[@]}"}")
		fi
	done
	[[ -z "$fallback" ]] || rm -f "$fallback"
	((${#best[@]} == 0)) || printf '%s\n' "${best[@]}"
}
