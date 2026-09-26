#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/slot_classify.py
#
# Strategy: the classifier is a stdin -> stdout filter printing one token. Every test feeds a
# comment page on stdin and asserts on that token. Timestamps are computed at run time, never
# frozen into a fixture file: three of the six cases turn on "is the stated wait still running",
# which a fixed timestamp answers correctly only on the day it was written.
#
# The cases below are the ones that found real defects (dotfiles-dev#433, #473):
#   1. a live-shaped page where an unrelated notice is NEWEST and masks a running limit;
#   2. the wrapper/sibling pair, where the newer of the two carries no stated wait;
#   3. a stated wait that has already expired;
#   4. a completed review posted after the last limit;
#   5. a forge 403 body — parses as JSON, is not a comment page;
#   6. garbage that is not JSON at all;
#   7. the SAME two-notice shape as case 1's chat/review split, fed in GitHub's real,
#      oldest-first REST order — pins dotfiles-dev#473 (an older CHAT-quota notice read as
#      "newest" masks a newer, still-running REVIEW limit).
# ⚠️ Cases 5 and 6 must print UNKNOWN. UNKNOWN must never read as free.
#
# Run locally: bats tests/slot_classify.bats

setup() {
    CLASSIFY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/slot_classify.py"
    # One clock read per test: ts() and reset_hhmm() both derive from it, so a minute
    # boundary crossed between building the input and computing the expectation cannot
    # make them disagree.
    NOW_EPOCH="$(date -u +%s)"
}

# ts MINUTES_AGO -> an ISO-8601 Z timestamp that many minutes in the past.
ts() {
    date -u -d "@$((NOW_EPOCH - $1 * 60))" +%Y-%m-%dT%H:%M:%SZ
}

# reset_hhmm MINUTES_AGO STATED_WAIT -> the HH:MM the classifier should report for a notice
# posted MINUTES_AGO carrying a STATED_WAIT-minute wait.
reset_hhmm() {
    date -u -d "@$((NOW_EPOCH + ($2 - $1) * 60))" +%H:%M
}

@test "an unrelated notice as the newest comment does not mask a running limit" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY'
[
  {\"user\": {\"login\": \"coderabbitai[bot]\"}, \"created_at\": \"$(ts 1)\",
   \"body\": \"> [!IMPORTANT]\\n> ## Review skipped\\n> This repository has fewer than 10 stars.\"},
  {\"user\": {\"login\": \"coderabbitai[bot]\"}, \"created_at\": \"$(ts 2)\",
   \"body\": \"> [!WARNING]\\n> ## Rate limit exceeded\\n> @guilhermegor has exceeded the limit. Please wait 26 minutes and 3 seconds before requesting another review.\\n> Reviews will be available in 27 minutes.\"},
  {\"user\": {\"login\": \"guilhermegor\"}, \"created_at\": \"$(ts 3)\", \"body\": \"lgtm\"}
]
JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "BUSY|until-$(reset_hhmm 2 27)Z" ]
}

@test "the wrapper comment carrying no wait does not degrade its sibling's stated wait" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY'
[
  {\"user\": {\"login\": \"coderabbitai[bot]\"}, \"created_at\": \"$(ts 1)\",
   \"body\": \"\\u26a0\\ufe0f Action not completed — Review rate limited.\"},
  {\"user\": {\"login\": \"coderabbitai[bot]\"}, \"created_at\": \"$(ts 2)\",
   \"body\": \"Rate limit exceeded. Reviews will be available in 27 minutes.\"}
]
JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "BUSY|until-$(reset_hhmm 2 27)Z" ]
    [[ "$output" != *"no-stated-wait"* ]]
}

@test "a stated wait that has already elapsed reports FREE, naming the expiry" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY'
[
  {\"user\": {\"login\": \"coderabbitai[bot]\"}, \"created_at\": \"$(ts 60)\",
   \"body\": \"Rate limit exceeded. Reviews will be available in 5 minutes.\"}
]
JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == "FREE|wait-expired-at-"* ]]
}

@test "a review that completed after the last limit reports FREE" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY'
[
  {\"user\": {\"login\": \"coderabbitai[bot]\"}, \"created_at\": \"$(ts 1)\",
   \"body\": \"Actionable comments posted: 0. Review finished.\"},
  {\"user\": {\"login\": \"coderabbitai[bot]\"}, \"created_at\": \"$(ts 30)\",
   \"body\": \"Rate limit exceeded. Reviews will be available in 90 minutes.\"}
]
JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "FREE|a-review-completed-after-the-last-limit" ]
}

@test "oldest-first REST order does not let an older CHAT notice mask a newer REVIEW limit" {
    run bash -c "cat <<JSON | python3 '$CLASSIFY'
[
  {\"user\": {\"login\": \"coderabbitai[bot]\"}, \"created_at\": \"$(ts 10)\",
   \"body\": \"You have exceeded the rate limit for chat messages. Please wait 5 minutes before sending another message.\"},
  {\"user\": {\"login\": \"coderabbitai[bot]\"}, \"created_at\": \"$(ts 1)\",
   \"body\": \"Rate limit exceeded. Reviews will be available in 30 minutes.\"}
]
JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "BUSY|until-$(reset_hhmm 1 30)Z" ]
    [[ "$output" != "FREE|chat-quota-only" ]]
}

@test "a forge 403 body is UNKNOWN, never free" {
    run bash -c "printf '%s' '{\"message\":\"API rate limit exceeded for user ID 1.\",\"documentation_url\":\"https://docs.github.com/rest\",\"status\":\"403\"}' | python3 '$CLASSIFY'"
    [ "$status" -eq 0 ]
    [ "$output" = "UNKNOWN" ]
}

@test "garbage on stdin is UNKNOWN, never free" {
    run bash -c "printf '%s' 'gh: command not found' | python3 '$CLASSIFY'"
    [ "$status" -eq 0 ]
    [ "$output" = "UNKNOWN" ]
}
