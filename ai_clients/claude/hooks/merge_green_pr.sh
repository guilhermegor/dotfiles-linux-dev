#!/bin/bash
# Stable entry point for squash-merging GREEN PRs (dotfiles-linux-dev#868).
#
# Usage: merge_green_pr.sh <pr-number>...      (run inside a clone of the PRs' repo)
#
# Exists so settings.json can allow exactly this path. On a single-maintainer repo no
# PR can get a human approval, so the auto-mode classifier denies every merge as "Merge
# Without Review". A glob rule on `gh pr merge` cannot help: measured on layouts-cvm, the
# GraphQL-backed `gh pr merge` failed on rate limit and the shapes that were denied were a
# bare `gh api -X PUT .../merge`, a `for` loop and a scratch script. Same precedent as
# run_ladder_review.sh (#738): one wrapper, one allow rule, the guards live inside it.
#
# Takes positive integers ONLY: no flags, so no --admin and no merge_method choice (always
# squash). REST only, zero GraphQL. Per PR it refuses unless the PR is not a draft, its
# mergeable_state is `clean`, and every required check-run on the head (the base branch's
# protection contexts PLUS "Review threads answered" when the repo has a workflow producing it; with neither
# that gate nor protection contexts, every check-run on the head) concluded `success`; an unreadable
# protection is UNKNOWN and fails closed. The merge PUT pins the head sha, so a push after
# the checks were read is refused by GitHub. Prints one line per PR; exits 1 if any was
# refused. OWNER/REPO come from the cwd's origin: from a shell already in the repo run it
# bare (`~/.claude/hooks/merge_green_pr.sh 27 29`, no `cd`); `cd <absolute-repo-path> && …`
# works too. A required check pinned to an app (protection app_id, ruleset integration_id)
# must come from that app's check-run; unpinned (null/-1) is matched by name.
#
# CI provenance (#1064): a PR can add or edit a workflow that posts a green check under a
# required name. So when the PR adds, changes or renames any .github/workflows/ file, EVERY
# GitHub Actions check-run carrying a required name (duplicates included) is traced
# check-run -> check_suite.id -> actions/runs?check_suite_id=... -> .path, and the PR is
# REFUSED if that workflow file is one the PR touched. An unresolvable path or failed read
# is UNKNOWN (fails closed). Checks from other apps keep the app_id matching only. Any
# .github/actions/ change is still refused (merge by hand). Also refused: a run that
# references (reusable workflow) a changed file; a required check-run with no job of that
# name in its run (an API-posted check); and any added/changed workflow (parsed with yq or
# PyYAML, aliases resolved; no parser is UNKNOWN) whose top-level `permissions` is missing,
# write-all or grants checks/statuses: write, or has a job-level one that does (it could
# POST a check). A required context met by a commit status or by a non-Actions check-run has
# no workflow to trace, so it refuses any PR that changes a workflow. A changed workflow
# filename outside [A-Za-z0-9._/-] is refused too (it is interpolated into a URL).
# An UNCHANGED workflow with checks/statuses: write that runs PR-controlled code is out of
# scope: it is already trusted on the base branch, and the old blanket rule did not cover it.
# The gate cannot see CI code that is not under .github/.
set -u

if [ "$#" -lt 1 ]; then
	echo "usage: merge_green_pr.sh <pr-number>... (positive integers only, no flags)" >&2
	exit 2
fi
for a in "$@"; do
	if [[ ! "$a" =~ ^[1-9][0-9]*$ ]]; then
		echo "usage: merge_green_pr.sh <pr-number>... (positive integers only, no flags)" >&2
		exit 2
	fi
done

slug="$(git remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')"
owner="${slug%%/*}"
repo="${slug#*/}"
if [ -z "$owner" ] || [ "$owner" = "$slug" ]; then
	echo "cannot derive OWNER/REPO from the origin remote" >&2
	exit 1
fi

GATE_CHECK="Review threads answered"

# READ-ONLY calls only (never the merge PUT). One retry, and only for a transient error:
# a deterministic 4xx (404/405/409/422) is final. Each attempt's output is held apart, so a
# paginated read that fails midway cannot leave partial rows in front of the retry's rows.
# ponytail: swap for gh_budget_with_backoff once it exists on master (gh_budget.sh only
# classifies today).
gh_retry() {
	local out err
	err="$(mktemp)" || return 1
	# </dev/null: callers run inside `while read` loops and gh must not eat their stdin.
	if out="$(gh "$@" 2>"$err" </dev/null)"; then
		rm -f "$err"
		printf '%s\n' "$out"
		return 0
	fi
	if grep -q -E 'HTTP (404|405|409|422)' "$err"; then
		rm -f "$err"
		return 1
	fi
	sleep "${MERGE_GREEN_RETRY_SLEEP:-2}"
	rm -f "$err"
	out="$(gh "$@" 2>/dev/null </dev/null)" || return 1
	printf '%s\n' "$out"
}

# Prints the base branch's required contexts: classic protection plus rulesets, one per line.
# "Branch not protected" (404) is an empty list; any other read failure fails the call.
required_contexts() {
	local base="$1" err classic rules
	err="$(mktemp)" || return 1
	if ! classic="$(gh api "repos/$owner/$repo/branches/$base/protection" \
		--jq '[((.required_status_checks.contexts // [])[] | [., "-1"]), ((.required_status_checks.checks // [])[] | [.context, ((.app_id // -1)|tostring)])] | .[] | @tsv' 2>"$err")"; then
		if grep -q 'Branch not protected' "$err"; then
			classic=""
		else
			rm -f "$err"
			return 1
		fi
	fi
	rm -f "$err"
	rules="$(gh_retry api --paginate "repos/$owner/$repo/rules/branches/$base" \
		--jq '.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | [.context, ((.integration_id // -1)|tostring)] | @tsv')" || return 1
	printf '%s\n%s\n' "$classic" "$rules" | sed '/^$/d'
}

# Does the base branch carry a workflow that produces the review gate? 0 yes, 1 no, 2 unreadable.
# A repo without one (only a README-parity workflow, say) can never post the check, so
# requiring it would make the wrapper unusable there (#1113). A missing .github/workflows
# directory (404), or one holding no .yml/.yaml, is "no workflow"; any other read failure is UNKNOWN, never "no gate".
repo_has_gate_workflow() {
	local base="$1" err files f content parsed
	err="$(mktemp)" || return 2
	if ! files="$(gh api "repos/$owner/$repo/contents/.github/workflows?ref=$base" \
		--jq '.[] | select(.type=="file" and (.name | test("\\.ya?ml$"))) | .path' 2>"$err" </dev/null)"; then
		if grep -q 'HTTP 404' "$err"; then rm -f "$err"; return 1; fi
		rm -f "$err"; return 2
	fi
	rm -f "$err"
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		content="$(gh_retry api "repos/$owner/$repo/contents/$f?ref=$base" --jq .content | base64 -d 2>/dev/null)" && [ -n "$content" ] || return 2
		parsed="$(workflow_json <<<"$content")" && [ -n "$parsed" ] || return 2
		# Parsed, so comments are gone and quoting is decoded. A job named for the gate or a
		# step that POSTs it (this repo's own workflows do both) produces it.
		jq -e --arg g "$GATE_CHECK" '[(.jobs // {})[] | (.name // empty), (.steps[]? | .run // empty)] | any(.[]; type == "string" and contains($g))' <<<"$parsed" >/dev/null 2>&1 && return 0
	done <<<"$files"
	return 1
}

# Workflow YAML on stdin -> JSON on stdout, aliases resolved. No parser is a failure, so the
# caller fails closed (UNKNOWN). Considered and rejected: refusing any workflow change.
workflow_json() {
	local src out
	src="$(cat)"
	# yq may be a flavour without `-o=json` (kislyuk, mikefarah v3): fall through, never stop.
	if command -v yq >/dev/null 2>&1 && out="$(yq -o=json 'explode(.)' <<<"$src" 2>/dev/null)" && [ -n "$out" ]; then
		printf '%s\n' "$out"
	elif python3 -c 'import yaml' >/dev/null 2>&1; then
		python3 -c 'import sys, json, yaml; print(json.dumps(yaml.safe_load(sys.stdin)))' <<<"$src"
	else
		return 1
	fi
}

# Allowlist, never a denylist: a top-level `permissions` that is read-all or a mapping whose
# every value is read/none, and every job-level `permissions` absent, read-all, or with
# checks/statuses absent/read/none. Any other value (Write, bogus, write-all) is unsafe.
PERMISSIONS_SAFE='def lvl: . == "read" or . == "none";
	def top: (type == "string" and . == "read-all") or (type == "object" and all(.[]; lvl));
	def job: (type == "string" and . == "read-all")
		or (type == "object" and (has("<<") | not) and all(("checks", "statuses") as $k | if has($k) then .[$k] | lvl else true end; .));
	type == "object" and has("permissions") and (.permissions | top)
	and all((.jobs // {})[]; (type == "object") and ((has("permissions") | not) or (.permissions | job)))'

# A Dependabot PR is trusted only when the branch is Dependabot's own: a dependabot/* head in
# this repo, and every commit authored by the bot, committed by it or GitHub's web-flow, and
# signature-verified. Shape taken from a real Dependabot PR (author dependabot[bot], committer
# web-flow, verified). Any other commit (a human's, an agent's push, "Update branch") refuses.
bot_provenance() {
	local pr="$1" head_ref="$2" head_repo="$3" base_repo="$4" commits total
	[[ "$head_ref" == dependabot/* ]] ||
		{ echo "#$pr REFUSED: dependabot PR head ref '$head_ref' is not dependabot/* — merge by hand"; return 1; }
	[ "$head_repo" != "-" ] && [ "${head_repo,,}" = "${base_repo,,}" ] ||
		{ echo "#$pr REFUSED: dependabot PR head repo '$head_repo' is not '$base_repo' — merge by hand"; return 1; }
	commits="$(gh_retry api --paginate "repos/$owner/$repo/pulls/$pr/commits?per_page=100" \
		--jq '.[] | [(.author.login // "-"), (.committer.login // "-"), ((.commit.verification.verified // false)|tostring)] | @tsv')" && [ -n "$commits" ] ||
		{ echo "#$pr UNKNOWN: cannot read the PR's commits"; return 1; }
	total="$(grep -c . <<<"$commits")"
	# The commits endpoint stops at 250, so a full page could hide a later foreign commit.
	[ "$total" -lt 250 ] ||
		{ echo "#$pr REFUSED: commit list may be truncated — merge by hand"; return 1; }
	if awk -F'\t' '{a=tolower($1); c=tolower($2)} !(a=="dependabot[bot]" && (c=="dependabot[bot]" || c=="web-flow") && $3=="true") {f=1} END {exit !f}' <<<"$commits"; then
		echo "#$pr REFUSED: dependabot PR carries a commit not authored by dependabot[bot] or not verified — merge by hand"
		return 1
	fi
}

merge_one() {
	local pr="$1" info head state draft base author changed try head_ref head_repo base_repo
	local required checks statuses bad name files wf_changed wf_live wpath rname suite
	local rid rpath refs jobs backed content wf parsed

	# mergeable_state is computed lazily: poll while GitHub still says unknown/null.
	for try in 1 2 3; do
		info="$(gh_retry api "repos/$owner/$repo/pulls/$pr" \
			--jq '[(.head.sha // "-"), (.mergeable_state // "unknown"), ((.draft // false)|tostring), (.base.ref // "-"), (.user.login // "-"), ((.changed_files // "-")|tostring), (.head.ref // "-"), (.head.repo.full_name // "-"), (.base.repo.full_name // "-")] | @tsv')" && [ -n "$info" ] ||
			{ echo "#$pr UNKNOWN: cannot read the PR"; return 1; }
		# "-" placeholders keep every field non-empty: tab is IFS whitespace and would
		# otherwise collapse an empty field and shift the columns.
		IFS=$'\t' read -r head state draft base author changed head_ref head_repo base_repo <<<"$info"
		[ "$state" = "unknown" ] || break
		[ "$try" -lt 3 ] && sleep "${MERGE_GREEN_RETRY_SLEEP:-2}"
	done
	{ [ "$head" != "-" ] && [ "$base" != "-" ] && [ "$author" != "-" ] && [[ "$changed" =~ ^[0-9]+$ ]]; } ||
		{ echo "#$pr UNKNOWN: malformed PR read"; return 1; }
	# GitHub logins are case-insensitive.
	# Dependabot is the one bot allowed (#1076), but the PR author is only whoever opened the PR:
	# anyone able to push to a dependabot/* branch keeps that author. So its PRs also need the
	# commit provenance below; every check after it applies to it unchanged, rules (0)-(2) too.
	if [ "${author,,}" != "${me,,}" ]; then
		[ "${author,,}" = "dependabot[bot]" ] ||
			{ echo "#$pr REFUSED: author '$author' is not '$me' or dependabot[bot] — merge by hand"; return 1; }
		bot_provenance "$pr" "$head_ref" "$head_repo" "$base_repo" || return 1
	fi
	[ "$draft" = "false" ] || { echo "#$pr REFUSED: draft"; return 1; }
	# has_hooks is clean with pre-receive hooks; both are mergeable.
	[[ "$state" == "clean" || "$state" == "has_hooks" ]] ||
		{ echo "#$pr REFUSED: mergeable_state is '$state', not clean"; return 1; }

	files="$(gh_retry api --paginate "repos/$owner/$repo/pulls/$pr/files?per_page=100" --jq '.[] | [.filename, (.previous_filename // ""), (.status // "")] | @tsv')" ||
		{ echo "#$pr UNKNOWN: cannot read the PR's files"; return 1; }
	# The files endpoint stops at 3000, so a short list could hide a .github/ change.
	if [ "$(grep -c . <<<"$files")" -ne "$changed" ]; then
		echo "#$pr REFUSED: file list incomplete — merge by hand"
		return 1
	fi
	# Either column: a rename out of .github/ keeps the old path in previous_filename.
	if grep -q -E $'(^|\t)\\.github/actions/' <<<"$files"; then
		echo "#$pr REFUSED: touches .github/actions — merge by hand"
		return 1
	fi
	# Workflow files the PR added, changed or renamed (either column).
	wf_changed="$(cut -f1,2 <<<"$files" | tr '\t' '\n' | grep -E '^\.github/workflows/' | sort -u)"
	# Of those, the ones still present at the head (a removed file cannot post anything).
	wf_live="$(awk -F'\t' '$1 ~ /^\.github\/workflows\// && $3!="removed" {print $1}' <<<"$files" | sort -u)"

	required="$(required_contexts "$base")" ||
		{ echo "#$pr UNKNOWN: cannot read the required checks of $base"; return 1; }
	# The gate is required only where a workflow produces it; with no gate and no protection or
	# ruleset contexts, every check-run on the head is required (set below, once read).
	repo_has_gate_workflow "$base"
	case $? in
		0) required="$(printf '%s\n%s\t-1\n' "$required" "$GATE_CHECK" | sed '/^$/d' | sort -u)" ;;
		1) ;;
		*) echo "#$pr UNKNOWN: cannot read the workflows of $base"; return 1 ;;
	esac

	# Checks API plus the commit Status API (a required context may be posted via either).
	# State is normalised to "success"; GitHub counts skipped/neutral as passing, so they
	# are accepted too, except for the review gate itself (strict success).
	checks="$(gh_retry api --paginate "repos/$owner/$repo/commits/$head/check-runs?per_page=100" \
		--jq '.check_runs[] | [.name, (.conclusion // "pending"), "::check::", ((.app.id // -1)|tostring), ((.check_suite.id // "-")|tostring)] | @tsv')" ||
		{ echo "#$pr UNKNOWN: cannot read check-runs of $head"; return 1; }
	# A commit status is forgeable by any token with repo access, this account's own gh
	# included (a personal token cannot create a check-run). So a status never satisfies
	# the review gate, and for any other context it counts only when its creator is not
	# the authenticated user. Third column: "::check::" for a check-run, else the creator.
	statuses="$(gh_retry api "repos/$owner/$repo/commits/$head/status" \
		--jq '.statuses[] | [.context, .state, (.creator.login // "-"), "-", "-"] | @tsv')" ||
		{ echo "#$pr UNKNOWN: cannot read commit statuses of $head"; return 1; }
	checks="$(printf '%s\n%s\n' "$checks" "$statuses")"
	if [ -z "$required" ]; then
		required="$(awk -F'\t' '$3=="::check::" {print $1 "\t-1"}' <<<"$checks" | sort -u)"
		[ -n "$required" ] ||
			{ echo "#$pr REFUSED: no required checks and no check-run on the head to prove green"; return 1; }
	fi

	# Provenance: only matters when the PR touched a workflow. Actions app id is 15368.
	if [ -n "$wf_changed" ]; then
		# (0) A commit status carries no check_suite, so its creator cannot be traced to a
		# workflow. Fail closed: a required context met by a status refuses any workflow change.
		if awk -F'\t' 'NR==FNR {req[$1]=1; next} $3!="::check::" && ($1 in req) {f=1} END {exit !f}' <(cut -f1 <<<"$required") - <<<"$checks"; then
			echo "#$pr REFUSED: a required context is satisfied by a commit status and this PR changes a workflow"
			return 1
		fi
		# (0b) A check-run from any app other than GitHub Actions cannot be traced to a workflow,
		# and a dropped job leaves its name free for an App token to post under. Fail closed.
		if awk -F'\t' 'NR==FNR {req[$1]=1; next} $3=="::check::" && $4!="15368" && ($1 in req) {f=1} END {exit !f}' <(cut -f1 <<<"$required") - <<<"$checks"; then
			echo "#$pr REFUSED: a required context is satisfied by a non-Actions check-run and this PR changes a workflow"
			return 1
		fi
		# (0c) The path goes into a URL unescaped, so ?, & or # would redirect the contents read
		# to another revision; tab/newline would break the TSV columns. Allowlist the charset.
		if grep -q -v -E '^[A-Za-z0-9._/-]+$' <<<"$wf_changed"; then
			echo "#$pr REFUSED: a changed workflow filename has characters outside [A-Za-z0-9._/-]"
			return 1
		fi
		# (1) Forgery: a changed workflow whose GITHUB_TOKEN may write checks could POST a
		# check-run under a required name. No top-level `permissions:` means the repo default
		# applies, which cannot be proven safe from the file, so that refuses too.
		while IFS= read -r wpath; do
			[ -n "$wpath" ] || continue
			content="$(gh_retry api "repos/$owner/$repo/contents/$wpath?ref=$head" --jq .content | base64 -d 2>/dev/null)" && [ -n "$content" ] ||
				{ echo "#$pr UNKNOWN: cannot read $wpath at $head"; return 1; }
			parsed="$(workflow_json <<<"$content")" && [ -n "$parsed" ] ||
				{ echo "#$pr UNKNOWN: cannot parse $wpath (no YAML parser, or invalid YAML)"; return 1; }
			jq -e "$PERMISSIONS_SAFE" <<<"$parsed" >/dev/null 2>&1 ||
				{ echo "#$pr REFUSED: changed workflow $wpath may grant checks: write (permissions not provably safe)"; return 1; }
		done <<<"$wf_live"
		# (2) Each required Actions check-run: its run and every reusable workflow that run
		# references must be unchanged, and the run must have a job of that name.
		while IFS=$'\t' read -r rname suite; do
			[ -n "$rname" ] || continue
			# A suite with no runs is unresolvable, never assumed clean.
			wpath="$(gh_retry api "repos/$owner/$repo/actions/runs?check_suite_id=$suite" \
				--jq '.workflow_runs[] | [.id, .path, ((.referenced_workflows // []) | map(.path) | join(" "))] | @tsv')" && [ -n "$wpath" ] ||
				{ echo "#$pr UNKNOWN: cannot resolve the workflow of required check [$rname]"; return 1; }
			backed=""
			while IFS=$'\t' read -r rid rpath refs; do
				for wf in $rpath $refs; do
					wf="$(sed -E 's/@.*//; s#^.*(\.github/workflows/)#\1#' <<<"$wf")"
					if grep -q -x -F -- "$wf" <<<"$wf_changed"; then
						echo "#$pr REFUSED: required check [$rname] came from $wf, which this PR changes"
						return 1
					fi
				done
				jobs="$(gh_retry api --paginate "repos/$owner/$repo/actions/runs/$rid/jobs?per_page=100" --jq '.jobs[].name')" ||
					{ echo "#$pr UNKNOWN: cannot read the jobs of run $rid"; return 1; }
				if grep -q -x -F -- "$rname" <<<"$jobs"; then backed=1; fi
			done <<<"$wpath"
			[ -n "$backed" ] || { echo "#$pr REFUSED: required check [$rname] has no backing job in its run"; return 1; }
		done < <(awk -F'\t' 'NR==FNR {req[$1]=1; next} $3=="::check::" && $4=="15368" && ($1 in req) {print $1 "\t" $5}' <(cut -f1 <<<"$required") - <<<"$checks" | sort -u)
	fi

	bad=""
	while IFS=$'\t' read -r name app; do
		# No app_id (empty, null or -1) means any app; otherwise the check-run's app.id must
		# equal it. A commit status carries no app ("-"), so it never meets a pinned app.
		{ [ -z "$app" ] || [ "$app" = "null" ]; } && app="-1"
		# Every counted run with this name must pass; a missing or mixed name is not green.
		if ! awk -F'\t' -v n="$name" -v app="$app" -v gate="$GATE_CHECK" -v me="${me,,}" '
			$1==n && (app=="-1" || $4==app) {
				if ($3!="::check::" && (n==gate || tolower($3)==me)) next
				seen=1
				ok=($2=="success" || (n!=gate && ($2=="skipped" || $2=="neutral")))
				if (!ok) fail=1
			}
			END {exit !(seen && !fail)}' <<<"$checks"; then
			bad="$bad [$name]"
		fi
	done <<<"$required"
	[ -z "$bad" ] || { echo "#$pr REFUSED: required check not green:$bad"; return 1; }

	# The PUT is never retried: a call that succeeded server-side but errored client-side
	# would be re-sent into a 405/409 and misreported. On failure, ask whether it merged.
	if gh api -X PUT "repos/$owner/$repo/pulls/$pr/merge" \
		-f merge_method=squash -f sha="$head" >/dev/null 2>&1; then
		echo "#$pr MERGED squash at ${head:0:12}"
	elif [ "$(gh_retry api "repos/$owner/$repo/pulls/$pr" --jq .merged 2>/dev/null)" = "true" ]; then
		echo "#$pr MERGED squash at ${head:0:12} (PUT errored, PR is merged)"
	else
		echo "#$pr REFUSED: merge PUT failed (head moved, or branch protection blocks it)"
		return 1
	fi
}

main() {
	local pr rc=0
	# The remote is writable by an agent, so the target is trusted only if its owner is
	# the authenticated user; each PR's author must be that user, or dependabot[bot] with
	# bot_provenance (other bots go to a prompt).
	me="$(gh_retry api user --jq .login)" && [ -n "$me" ] ||
		{ echo "UNKNOWN: cannot read the authenticated user"; return 1; }
	# Case-insensitive; an org-owned repo never equals a user login, so it is refused on
	# purpose (merge those by hand).
	if [ "${owner,,}" != "${me,,}" ]; then
		echo "REFUSED: repo owner '$owner' is not '$me' — merge by hand"
		return 1
	fi
	for pr in "$@"; do
		merge_one "$pr" || rc=1
	done
	return "$rc"
}

main "$@"
