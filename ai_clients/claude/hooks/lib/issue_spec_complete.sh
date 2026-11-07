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

# _spec_section TEXT HEADER_SUBSTR
# Prints the lines of the first `##`/`###` section whose header line contains HEADER_SUBSTR
# (case-insensitive), up to the next such header or EOF. Prints nothing, returns 1 when absent.
_spec_section() {
	local text="$1" header_substr="$2" start_line next_line
	# Heading lines only: prose like "Scope follows" must not stand in for a `## Scope` heading.
	start_line="$(grep -n -E '^#{2,3}[[:space:]]' <<<"$text" | grep -i -F -- "$header_substr" \
		| head -n1 | cut -d: -f1)"
	[[ -n "$start_line" ]] || return 1
	next_line="$(tail -n "+$((start_line + 1))" <<<"$text" | grep -n -E '^#{2,3}[[:space:]]' | head -n1 | cut -d: -f1)"
	if [[ "$next_line" == 1 ]]; then
		return 0   # adjacent heading: the section is empty, not the next heading's line
	elif [[ -n "$next_line" ]]; then
		sed -n "$((start_line + 1)),$((start_line + next_line - 1))p" <<<"$text"
	else
		sed -n "$((start_line + 1)),\$p" <<<"$text"
	fi
}

# True if $1 (a multi-line block of text) has a `##`/`###` header matching $2 (case-insensitive
# substring) whose section (up to the next such header, or EOF) contains a `- [ ]`/`- [x]` item.
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
	# Inline `<!-- … -->` goes first so prose beside it survives; multi-line comments after.
	sed -E 's/<!--.*-->//g' <<<"$section" \
		| awk '/^```surface/ { s=1; next } s { if ($0 ~ /^```/) s=0; next }
			/<!--/ { c=1 } c { if ($0 ~ /-->/) c=0; next } { print }' \
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
	' <<<"$1"
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
	if ((${#templates[@]} == 0)); then
		fallback="$(mktemp)"
		printf '## What / Why\n' >"$fallback"
		templates=("$fallback")
	fi
	for template in "${templates[@]}"; do
		evaluate_template "$template" "$body" "${SPEC_LABELS:-}"
		reasons=("${missing[@]}")
		stripped="$(strip_frontmatter_and_comments "$template")"
		while IFS= read -r line; do
			header="$(sed -E 's/^#+[[:space:]]*//; s/[[:space:]]+$//' <<<"$line")"
			[[ -n "$header" && "${header,,}" != *surface* ]] || continue
			# evaluate_template matched the header text anywhere; the heading line itself is
			# required here, and its section must hold text.
			if ! _spec_section "$body" "$header" >/dev/null; then
				[[ " ${reasons[*]} " == *" $header "* ]] || reasons+=("$header")
			elif ! spec_section_filled "$body" "$header"; then
				reasons+=("empty $header")
			fi
		done < <(grep -E '^#{2,3}[[:space:]]' <<<"$stripped")
		spec_surface_nonempty "$body" || reasons+=("no surface block")
		if ((best_n == -1 || ${#reasons[@]} < best_n)); then
			best_n=${#reasons[@]}
			best=("${reasons[@]}")
		fi
	done
	[[ -z "$fallback" ]] || rm -f "$fallback"
	((${#best[@]} == 0)) || printf '%s\n' "${best[@]}"
}
