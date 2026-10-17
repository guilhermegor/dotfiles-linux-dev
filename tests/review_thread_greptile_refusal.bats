#!/usr/bin/env bats
#
# dotfiles-linux-dev#804: Greptile's trial-credit refusal arrives as a submitted
# COMMENTED review. It is not a review of the head, so the required
# "Review threads answered" gate must not count it (measured: #801 went green on
# a refusal alone). Fixtures are offline; the body is #801's, verbatim.

setup() {
    GATE="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/review_thread_gate.sh"
    # shellcheck source=/dev/null
    source "$GATE"
    REFUSAL='`guilhermegor` has reached the 50-credit limit for trial accounts. To continue receiving code reviews, [upgrade your plan](https://app.greptile.com/review/github).'
}

# reported_by <login> <body>: the reported filter over ONE submitted review on the head.
reported_by() {
    jq -nc --arg l "$1" --arg b "$2" '
      { data: { repository: { pullRequest: {
          reviews: { nodes: [ { author: {login:$l, __typename:"Bot"}, state:"COMMENTED",
                                body:$b, commit:{oid:"h0"} } ] },
          comments: { nodes: [] },
          commits: { nodes: [ { commit: { oid:"h0", committedDate:"2026-01-01T00:00:00Z" } } ] } } } } }' |
        jq -r --arg roster "$1" --arg marker "$_gate_ladder_marker_re" \
            --arg refusal "$(_gate_greptile_refusal_phrases)" "$(_gate_reported_filter)"
}

# review_count <login> <body>: the workflow's review count over ONE review.
review_count() {
    jq -nc --arg l "$1" --arg b "$2" '{reviews:[{author:{login:$l},body:$b}]}' |
        jq -r --arg refusal "$(_gate_greptile_refusal_phrases)" "$(_gate_real_review_count_filter)"
}

@test "refusal by greptile-apps (GraphQL login) is not a report" {
    [ "$(reported_by greptile-apps "$REFUSAL")" = "false" ]
}

@test "refusal by greptile-apps[bot] (REST login) is not a report" {
    [ "$(reported_by 'greptile-apps[bot]' "$REFUSAL")" = "false" ]
}

@test "a real Greptile review still counts" {
    [ "$(reported_by greptile-apps $'<!-- greptile_summary -->\nLooks fine')" = "true" ]
}

@test "the refusal phrase from a non-Greptile login is ignored" {
    [ "$(reported_by coderabbitai "$REFUSAL")" = "true" ]
    [ "$(reported_by not-greptile-apps "$REFUSAL")" = "true" ]
}

@test "workflow review count: refusal is 0, a real Greptile review and other bots are 1" {
    [ "$(review_count greptile-apps "$REFUSAL")" = "0" ]
    [ "$(review_count greptile-apps 'real review')" = "1" ]
    [ "$(review_count coderabbitai "$REFUSAL")" = "1" ]
}
