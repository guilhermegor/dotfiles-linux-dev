"""Classify the review slot from a page of reviewer roster notices on stdin.

Prints exactly one token: ``FREE|<reason>``, ``BUSY|<reason>`` or ``UNKNOWN``.

⚠️ ``UNKNOWN`` is the fail-closed answer and must never be read as free — it means
the page could not be classified (unparseable body, a forge error page, a 403),
not that the slot is idle. s:dev-loop step 4b spends the slot on that verdict.

Reviewer-agnostic by construction: every vendor-specific phrase lives in the
constants below, so pointing this at a different review bot is an edit to those
five strings and nothing else.

Lives in its own file rather than inline in the watcher: the first version embedded
this in ``python3 -c '...'`` inside a shell script, where the f-string's escaped
quotes survived the single quotes literally and Python raised SyntaxError on every
poll. The watcher reported UNKNOWN (fail-closed, correctly) instead of a slot state,
for 3 minutes before it was caught (dotfiles-dev#433).
"""

import datetime
import json
import re
import sys

# The reviewer this roster belongs to, and the five phrases its notices use.
# Vendor wording is data, never scattered through the logic below.
REVIEWER_LOGIN_SUBSTRING = "coderabbit"
LIMIT_PHRASES = ("rate limit", "review limit reached")
CHAT_QUOTA_PHRASE = "chat message"
REVIEW_DONE_PHRASE = "review finished"
RE_STATED_WAIT = re.compile(r"available in (\d+) minutes?")


def body_of(dict_comment: dict) -> str:
	"""Return a comment's body, lowercased, tolerating a missing or null field.

	Parameters
	----------
	dict_comment : dict
		One comment record from the roster page.

	Returns
	-------
	str
		The lowercased body, or an empty string when absent.
	"""
	return (dict_comment.get("body") or "").lower()


def classify(list_comments: list) -> str:
	"""Return the slot verdict for one page of roster comments.

	Parameters
	----------
	list_comments : list
		Comment records as returned by the forge's comment listing.

	Returns
	-------
	str
		``FREE|<reason>``, ``BUSY|<reason>`` or ``UNKNOWN``.
	"""
	list_bot = [
		c
		for c in list_comments
		if REVIEWER_LOGIN_SUBSTRING in ((c.get("user") or {}).get("login") or "").lower()
	]
	if not list_bot:
		return "FREE|no-notice-on-this-page"

	# ⚠️ GitHub's REST comment listing is OLDEST-first, but the two `next()` calls below
	# pick "the" limit/done notice by taking the FIRST match in list order — that is only
	# "the newest one" if the caller already reversed the page. Sort defensively here
	# instead of trusting every call site to remember that: a silently wrong "newest" reads
	# as a right answer (dotfiles-dev#473). Measured impact: mixing up an older CHAT-quota
	# notice for a newer REVIEW-limit notice inverts the verdict, since the two mean
	# opposite things for the slot (CHAT = a different quota, untouched review slot).
	list_bot = sorted(list_bot, key=lambda c: c.get("created_at") or "", reverse=True)

	# ⚠️ Only two notice kinds carry slot state. Everything else the reviewer posts —
	# "this repository does not receive automatic reviews because it has fewer than 10
	# stars", trigger acknowledgements, summaries — is noise, and taking the newest
	# comment of ANY kind lets that noise mask a live rate limit. Measured 2026-09-20
	# 17:19Z: an agent opened a PR, its 10-stars notice became the newest comment,
	# and reading "no rate limit in this body" as FREE hid a limit running to 17:47Z.
	dict_limit = next(
		(c for c in list_bot if any(p in body_of(c) for p in LIMIT_PHRASES)),
		None,
	)
	dict_done = next((c for c in list_bot if REVIEW_DONE_PHRASE in body_of(c)), None)
	if dict_limit is None:
		return "FREE|no-rate-limit-notice-on-this-page"
	if dict_done is not None and (dict_done.get("created_at") or "") > (
		dict_limit.get("created_at") or ""
	):
		return "FREE|a-review-completed-after-the-last-limit"

	if CHAT_QUOTA_PHRASE in body_of(dict_limit):
		return "FREE|chat-quota-only"

	# ⚠️ One rate-limit event posts TWO comments, and the newest of the pair is the
	# `Action not completed` wrapper, which carries NO stated wait — the wait lives in
	# its sibling, posted seconds earlier. Reading only the newest therefore degrades
	# every limit to "no stated wait". Measured 2026-09-20: 17:20:11Z had none while
	# 17:19:58Z said 27 minutes. Take the LATEST reset any notice implies, so a fresh
	# limit posted while an older one is still running cannot shorten the window.
	dt_reset = None
	for dict_c in list_bot:
		cls_match = RE_STATED_WAIT.search(dict_c.get("body") or "")
		if not cls_match:
			continue
		str_posted = (dict_c.get("created_at") or "").replace("Z", "+00:00")
		dt_posted = datetime.datetime.fromisoformat(str_posted)
		dt_candidate = dt_posted + datetime.timedelta(minutes=int(cls_match.group(1)))
		if dt_reset is None or dt_candidate > dt_reset:
			dt_reset = dt_candidate

	if dt_reset is None:
		return "BUSY|rate-limited-no-stated-wait-on-this-page"

	str_reset = dt_reset.strftime("%H:%M")
	dt_now = datetime.datetime.now(datetime.timezone.utc)
	if dt_now >= dt_reset:
		return f"FREE|wait-expired-at-{str_reset}Z"
	return f"BUSY|until-{str_reset}Z"


def main() -> int:
	"""Read the comment page on stdin and print the slot verdict.

	Returns
	-------
	int
		Always 0; the verdict is the stdout token.
	"""
	try:
		list_comments = json.load(sys.stdin)
	except (json.JSONDecodeError, ValueError):
		print("UNKNOWN")
		return 0
	# A forge error body (403 quota, 404) parses as JSON but is an object, not a page
	# of comments. Everything that is not a list of records is UNKNOWN, never free.
	if not isinstance(list_comments, list):
		print("UNKNOWN")
		return 0

	try:
		print(classify(list_comments))
	except (AttributeError, KeyError, TypeError, ValueError):
		print("UNKNOWN")
	return 0


if __name__ == "__main__":
	sys.exit(main())
