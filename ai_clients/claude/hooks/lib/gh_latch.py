"""Read-only twin of gh_budget.sh's 403 latch, for the planners (dotfiles-linux-dev#814).

The path logic must match ``gh_budget_latch_path``; ``tests/stop_budget.bats`` round-trips a
marker written by ``gh_budget_latch_write`` through ``refuse_if_latched`` to catch drift.
"""

from __future__ import annotations

import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

LATCH_NAME = "dotfiles-dev-sweep-403-until"


def latch_path() -> Path:
	"""Return the marker path, honouring GH_BUDGET_LATCH_FILE like the bash side."""
	override = os.environ.get("GH_BUDGET_LATCH_FILE")
	if override:
		return Path(override)
	runtime = os.environ.get("XDG_RUNTIME_DIR", "")
	if runtime and Path(runtime).is_dir():
		return Path(runtime) / LATCH_NAME
	home = os.environ.get("HOME", "")
	if home:
		cache = Path(home) / ".cache"
		try:  # same as gh_budget_latch_default_dir: create it 0700 rather than skip to /tmp
			cache.mkdir(mode=0o700, parents=True, exist_ok=True)
			cache.chmod(0o700)
			return cache / LATCH_NAME
		except OSError:
			pass
	return Path("/tmp") / LATCH_NAME  # noqa: S108 - same last-resort fallback as gh_budget.sh


def latched_until() -> int | None:
	"""Return the epoch the latch expires at, or None when it is absent, bad, or expired."""
	try:
		until = int(latch_path().read_text().strip())
	except (OSError, ValueError):
		return None
	return until if time.time() < until else None


def refuse_if_latched(prog: str) -> bool:
	"""Print BUDGET-LOW to stderr and return True while the latch is active."""
	until = latched_until()
	if until is None:
		return False
	reset = datetime.fromtimestamp(until, tz=timezone.utc).strftime("%H:%MZ")
	when = f"resets {reset}"
	try:  # stop_budget_gate marks a latch whose end it had to guess (a refused probe has no resetAt)
		if int(Path(f"{latch_path()}.guess").read_text().strip()) == until:
			when = f"reset unknown, rechecking after {reset}"
	except (OSError, ValueError):
		pass
	print(f"{prog}: BUDGET-LOW ({when}) -- not calling gh", file=sys.stderr)
	return True


UNKNOWN_RESET_TTL = 120


def latch_on_refusal(text: str) -> bool:
	"""Latch for a short guessed window when ``text`` is GitHub's own API rate-limit refusal.

	A real query refused with "API rate limit [already] exceeded" is proof the budget is empty
	whatever ``rate_limit`` or a passing probe says (dotfiles-linux-dev#922), and the refusal
	carries no resetAt. Same two-anchor match as ``gh_budget_classify``; the ``.guess`` marker
	copies the latch's own expiry so ``refuse_if_latched`` says the reset is unknown.
	"""
	low = (text or "").lower()
	if not ("api rate limit" in low and "exceeded" in low):
		return False
	path = latch_path()
	until = str(int(time.time()) + UNKNOWN_RESET_TTL) + "\n"
	try:
		path.write_text(until)
		Path(f"{path}.guess").write_text(until)
	except OSError:
		return False
	return True
