#!/bin/bash
# PreToolUse (Bash matcher) hook: refuse to publish PR bodies, issue bodies and review replies
# in a language the repository does not write its documentation in.
#
# A repo whose README and docs are English has one reading audience and one voice. A PR body or
# a review reply in another language is not a private note — it is the durable record of WHY a
# change looks the way it does, read later by whoever did not live the session. Mixing languages
# there splits that record in two and quietly excludes half the readers of one half of it.
#
# Direction of the check, deliberately: the REPO decides, not the conversation. Talking through a
# problem in Portuguese is fine and stays fine; what gets *published* follows the documentation.
# So the guard reads the repo's own README, and only fires when that README is English and the
# body being posted is not.
#
# Scope — the three surfaces that publish prose:
#   gh pr create/edit --body …      gh issue create/edit --body …      gh api …/comments…  -f body=
# A `--body-file` is read from disk and checked the same way.
#
# Prefixing the command makes the guard stand aside, for the rare deliberate case:
#   ALLOW_NON_DOC_LANGUAGE=1 gh pr create --body "…"

set -uo pipefail

ESCAPE_HATCH='ALLOW_NON_DOC_LANGUAGE=1'

# Portuguese function words, lifted from the field-calibrated list in
# templates/python-common/bin/check_comment_language.py: every entry was checked against English,
# so none is also an English word and ONE hit is enough signal. Accents are NOT used as the
# signal — a legitimate data label like "Saídas" in an English body must not trip this.
#
# ⚠️ Every accented word is listed in its UNACCENTED form too. The source list came from a gate
# that reads source comments, where accents are typed normally — but this repo's commit
# convention is ASCII, so the same prose arrives as "nao"/"entao"/"tambem". Without the plain
# forms the guard misses exactly the register it is most likely to meet. Found by a control
# whose body scored 2 hits and sailed through.
PT_WORDS='ainda|antes|apenas|aqui|cada|com|das|depois|dos|então|entao|entre|essa|esse|esta|está|estão|estao|este|exige|faz|fica|foi|isso|mas|mesmo|muito|não|nao|nada|onde|para|pela|pelo|pode|porque|quando|que|sem|ser|sobre|também|tambem|todo|uma|uns'

# One hit is signal, but a body quoting a Portuguese identifier or a source column name should
# not be enough — require a handful so the guard never fires on a single quoted token.
MIN_HITS=4

doc_language_is_english() {
	# The repo's README is the authority on what language its documentation is written in.
	# Absent README → unknown, and an unknown must not be enforced as a rule.
	#
	# ⚠️ Resolve it from the repo ROOT, never the cwd. Looking in the current directory made the
	# guard a silent no-op for every command issued from a subdirectory — which is most of them.
	local root readme
	root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
	for readme in "$root/README.md" "$root/readme.md" "$root/README.MD"; do
		[ -f "$readme" ] || continue
		# Same test, applied to the README itself: enough Portuguese function words means the
		# documentation is Portuguese and this guard has nothing to say.
		if [ "$(count_pt_words "$(cat "$readme")")" -ge 12 ]; then
			return 1
		fi
		return 0
	done
	return 1
}

count_pt_words() {
	# Count Portuguese function-word hits in the given text, matching whole words only and
	# ignoring case. Fenced code blocks AND inline `code` spans are stripped first: a body may
	# legitimately quote Portuguese source code, a commit subject, a UI string, or a Gherkin
	# keyword without being WRITTEN in it — the quoted literal is data the surrounding prose
	# describes, not prose itself, and it must stay verbatim (and greppable) rather than being
	# translated away. Measured (dotfiles-linux-dev#187): a body that was entirely English prose, but
	# quoted `Quando`/`Então`-style keywords in backticks, still scored above MIN_HITS and was
	# blocked — the fenced-block strip alone does not cover an inline span.
	local text="$1"
	# The backticks are literal fence/span characters in the sed expressions, not a command
	# substitution — single quotes are exactly what is wanted here.
	# shellcheck disable=SC2016
	printf '%s\n' "$text" \
		| sed '/^[[:space:]]*```/,/^[[:space:]]*```/d' \
		| sed -E 's/`[^`]*`//g' \
		| grep -oiEw "$PT_WORDS" 2>/dev/null \
		| wc -l \
		| tr -d ' '
}

extract_body() {
	# Pull the prose out of the command: `--body "…"`, `-f body=…`, or `--body-file <path>`.
	#
	# ⚠️ Extraction runs through `jq`, NOT `sed`. `sed` is line-oriented, so it captured only the
	# FIRST LINE of a body — and every real PR or issue body is multi-line, which made this guard
	# blind to exactly the case it exists for. Measured: a multi-line Portuguese body scored 0
	# and sailed through, while the same text on one line blocked. jq's `s` flag makes `.` span
	# newlines, so the whole body is seen. ⚠️ In jq/Oniguruma the flag is "m", NOT "s" — the
	# opposite of PCRE, where "s" is DOTALL and "m" is multiline. Using "s" here silently kept
	# the first-line-only behaviour, which is how the bug survived its own fix. $1 = raw payload.
	local payload="$1" body=""
	body="$(printf '%s' "$payload" | jq -r '
		(.tool_input.command // "")
		| (capture("--body[= ]+\"(?<b>.*)\""; "m").b)
		// (capture("--body[= ]+'"'"'(?<b>.*)'"'"'"; "m").b)
		// (capture("-f[[:space:]]+body=\"(?<b>.*)\""; "m").b)
		// (capture("-f[[:space:]]+body='"'"'(?<b>.*)'"'"'"; "m").b)
		// empty' 2>/dev/null)"
	if [ -z "$body" ]; then
		local file
		file="$(printf '%s' "$payload" | jq -r '
			(.tool_input.command // "")
			| (capture("--body-file[= ]+[\"'"'"']?(?<f>[^\"'"'"'[:space:]]+)").f) // empty' 2>/dev/null)"
		[ -n "$file" ] && [ -f "$file" ] && body="$(cat "$file")"
	fi
	printf '%s' "$body"
}

main() {
	local payload tool command body hits

	payload="$(cat)"
	# jq parses the payload AND extracts the body, so it must be present before either.
	command -v jq >/dev/null 2>&1 || exit 0
	tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
	[[ "$tool" == "Bash" ]] || exit 0

	command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
	[[ -n "$command" ]] || exit 0

	# Only the three publishing surfaces.
	printf '%s' "$command" \
		| grep -Eq '(gh[[:space:]]+(pr|issue)[[:space:]]+(create|edit))|(gh[[:space:]]+api[^|]*comments)' \
		|| exit 0

	# ⚠️ The escape hatch must be an assignment PREFIXING the command, not a string appearing
	# anywhere in it — otherwise a body that merely quotes the variable name (this hook's own
	# error message does) disables the guard for that call.
	printf '%s' "$command" \
		| grep -Eq "(^|[;&|][[:space:]]*)${ESCAPE_HATCH}[[:space:]]" && exit 0

	git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
	doc_language_is_english || exit 0

	body="$(extract_body "$payload")"
	[[ -n "$body" ]] || exit 0

	hits="$(count_pt_words "$body")"
	[[ "$hits" -ge "$MIN_HITS" ]] || exit 0

	{
		echo "BLOCKED: this repository documents itself in English, so its PR bodies, issue"
		echo "bodies and review replies follow the same language. The body being posted reads"
		echo "as Portuguese (${hits} function-word hits)."
		echo
		echo "A PR body and a review reply are the durable record of WHY a change looks the way"
		echo "it does — read later by whoever did not live the session. Mixing languages there"
		echo "splits that record and excludes half the readers of one half of it."
		echo
		echo "Rewrite the body in English and re-run. Talking through the problem in another"
		echo "language is unaffected; this is only about what gets published."
		echo
		echo "Deliberate exception:  ${ESCAPE_HATCH} <your command>"
	} >&2
	exit 2
}

main "$@"
