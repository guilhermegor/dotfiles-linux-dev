"""Read the open-PR board one small GraphQL page at a time (dotfiles-linux-dev#600).

``gh pr list --limit 200 --json …reviews,comments,statusCheckRollup`` is one request whose
cost is the REQUESTED page size times every nested connection, not the number of PRs that
exist. Measured 2026-10-02 on a 31-PR board: HTTP 502/504 three times running while small
GraphQL calls answered normally, and a sibling shape rejected outright at "515,100 possible
nodes" against a 500,000 cap. ``--limit 20`` of the same fields answered in 8.5s.

So both planners (``review_fanout_plan.py``, ``dispatch_plan.py``) read through here instead:
``PAGE_SIZE`` PRs per request, an explicit ``first:``/``last:`` on every nested connection in
the caller's selection, pages fetched one after another (never in parallel -- the secondary
rate limit tripped under parallel load while the primary bucket still read 4,879/5,000).

FAILS CLOSED AS ONE UNIT. A page that fails raises, and the caller never sees the pages that
came before it: a partial board reads downstream as "these are all the open PRs", which is
the same lie a truncated ``--limit`` read told. Nothing here catches ``gh``'s own failure --
``subprocess.CalledProcessError``/``TimeoutExpired`` propagate to the planner's existing
handling -- and anything shaped wrong (no ``data``, a missing page, a ``hasNextPage`` with no
cursor to follow) raises ``RuntimeError`` rather than being read as an empty or final page.
"""

from __future__ import annotations

import json
from collections.abc import Callable

# Measured, not chosen: --limit 10 took 6.2s and --limit 20 took 8.5s (#600); the 200-PR
# single request is what failed. Past ~20 the per-page latency climbs toward the gateway timeout.
PAGE_SIZE = 20

_QUERY_HEAD = (
	"query($owner:String!,$name:String!,$first:Int!,$after:String){"
	"repository(owner:$owner,name:$name){"
	"pullRequests(states:OPEN,first:$first,after:$after){"
	"pageInfo{hasNextPage endCursor} nodes{"
)
_QUERY_TAIL = "}}}}"


def _page(raw: str) -> dict:
	"""Return the ``pullRequests`` object of one response, raising when it is not one."""
	try:
		page = json.loads(raw)["data"]["repository"]["pullRequests"]
		if not isinstance(page["nodes"], list) or not isinstance(
			page["pageInfo"]["hasNextPage"], bool
		):
			raise TypeError("nodes is not a list, or hasNextPage is not a bool")
	except (ValueError, KeyError, TypeError) as exc:
		raise RuntimeError(f"open-PR page is not a GraphQL pullRequests page: {exc!r}") from exc
	return page


def read_open_prs(
	selection: str,
	run: Callable[[list[str]], str],
	limit: int,
	slug: str | None = None,
) -> list[dict]:
	"""Return the raw GraphQL node of every open PR, at most ``limit`` of them.

	``selection`` is the field list inside ``nodes{…}``; every connection in it must carry its
	own ``first:``/``last:``. ``run`` is the caller's own ``gh`` runner, so each planner keeps
	its own timeout. ``slug`` (``owner/name``) is explicit for a caller that already resolved
	it; ``None`` lets ``gh`` fill ``{owner}``/``{repo}`` from the working directory, as ``gh pr
	list`` did.

	Stops once ``limit`` nodes are held without reading further: a caller compares the result
	against its own cap and refuses to print a plan from a list that may be incomplete.
	"""
	if slug is None:
		repo_args = ["-F", "owner={owner}", "-F", "name={repo}"]
	else:
		owner, _, name = slug.partition("/")
		# -f, not -F: -F coerces a numeric-looking repo name to an integer variable.
		repo_args = ["-f", f"owner={owner}", "-f", f"name={name}"]
	query = _QUERY_HEAD + selection + _QUERY_TAIL

	nodes: list[dict] = []
	cursor = ""
	while len(nodes) < limit:
		cmd = ["gh", "api", "graphql", *repo_args, "-F", f"first={PAGE_SIZE}", "-f", f"query={query}"]
		if cursor:
			cmd += ["-f", f"after={cursor}"]
		page = _page(run(cmd))
		nodes.extend(page["nodes"])
		if not page["pageInfo"]["hasNextPage"]:
			break
		cursor = page["pageInfo"].get("endCursor") or ""
		if not cursor:
			raise RuntimeError("open-PR page reports hasNextPage but carries no endCursor")
	return nodes
