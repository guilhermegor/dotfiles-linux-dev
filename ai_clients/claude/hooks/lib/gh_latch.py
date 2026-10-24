"""Read-only twin of gh_budget.sh's 403 latch, for the planners (dotfiles-linux-dev#814).

The path logic must match ``gh_budget_latch_path``; ``tests/stop_budget.bats`` pins both
sides to the same marker so they cannot drift.
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
	print(f"{prog}: BUDGET-LOW (resets {reset}) -- not calling gh", file=sys.stderr)
	return True
