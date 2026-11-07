"""Read-only twin of gh_budget.sh's 403 latch, for the planners (dotfiles-linux-dev#814).

The path logic must match ``gh_budget_latch_path``; ``tests/stop_budget.bats`` round-trips a
marker written by ``gh_budget_latch_write`` through ``refuse_if_latched`` to catch drift.
"""

from __future__ import annotations

import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

LATCH_NAME = "dotfiles-dev-sweep-403-until"


def latch_path() -> Path:
	"""Return the marker path, honouring GH_BUDGET_LATCH_FILE like the bash side."""
	override = os.environ.get("GH_BUDGET_LATCH_FILE")
	if override:
		return Path(override)
	return _default_dir() / LATCH_NAME


def _default_dir() -> Path:
	"""Return gh_budget_latch_default_dir's directory (runtime dir, ~/.cache, else /tmp)."""
	runtime = os.environ.get("XDG_RUNTIME_DIR", "")
	if runtime and Path(runtime).is_dir():
		return Path(runtime)
	home = os.environ.get("HOME", "")
	if home:
		cache = Path(home) / ".cache"
		try:  # same as gh_budget_latch_default_dir: create it 0700 rather than skip to /tmp
			cache.mkdir(mode=0o700, parents=True, exist_ok=True)
			cache.chmod(0o700)
			return cache
		except OSError:
			pass
	return Path("/tmp")  # noqa: S108 - same last-resort fallback as gh_budget.sh


def log_spend(points: int = 0, caller: str = "") -> None:
	"""Append one line to the GraphQL spend log gh_budget_log_spend writes (#922); best-effort, never raises.

	Same file and ``epoch<TAB>caller<TAB>points`` shape, so ``gh_spend_summary.sh`` ranks planner
	calls beside the thread gate. The cost of a ``gh pr list`` is not exposed, so callers pass 0
	and the call still counts. The bare /tmp fallback is never appended to (planted-symlink risk).
	"""
	override = os.environ.get("GH_BUDGET_SPEND_LOG")
	base = _default_dir()
	if not override and str(base) == "/tmp":  # noqa: S108
		return
	path = Path(override) if override else base / "dotfiles-dev-graphql-spend.tsv"
	name = (caller or os.environ.get("GH_BUDGET_CALLER") or Path(sys.argv[0]).name).replace("\t", " ").replace("\n", " ")
	try:
		import fcntl

		with open(f"{path}.lock", "a") as lock:
			deadline = time.monotonic() + 2  # bounded like the shell side's `flock -w 2`
			while True:
				try:
					fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
					break
				except BlockingIOError:
					if time.monotonic() >= deadline:
						return
					time.sleep(0.05)
			with open(path, "a") as handle:
				handle.write(f"{int(time.time())}\t{name}\t{max(points, 0)}\n")
			try:
				cap = int(os.environ.get("GH_BUDGET_SPEND_LOG_MAX", "2000"))
			except ValueError:
				cap = 2000
			if cap < 2:
				cap = 2000
			lines = path.read_text().splitlines(keepends=True)
			if len(lines) > cap:
				_replace_atomically(path, "".join(lines[-(cap // 2):]))
	except (OSError, ValueError):
		pass


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


def is_rate_limit_refusal(text: str) -> bool:
	"""Return True for GitHub's own "API rate limit [already] exceeded" text (``gh_budget_classify``'s match)."""
	low = (text or "").lower()
	return "api rate limit" in low and "exceeded" in low


def latch_on_refusal(text: str) -> bool:
	"""Latch for a short guessed window when ``text`` is GitHub's own API rate-limit refusal.

	A real query refused with "API rate limit [already] exceeded" is proof the budget is empty
	whatever ``rate_limit`` or a passing probe says (dotfiles-linux-dev#922), and the refusal
	carries no resetAt. The ``.guess`` marker copies the latch's own expiry so
	``refuse_if_latched`` says the reset is unknown; it is written FIRST, so a failed marker
	write never leaves a latch whose guessed end would print as a known reset. A later expiry
	already recorded (a real resetAt) is kept, never shortened. Returns True when a latch is in
	force afterwards, False for a non-refusal or a failed write.
	"""
	if not is_rate_limit_refusal(text):
		return False
	expiry = int(time.time()) + UNKNOWN_RESET_TTL
	existing = latched_until()
	if existing is not None and existing >= expiry:
		return True
	path = latch_path()
	guess = Path(f"{path}.guess")
	try:
		previous = guess.read_text()
	except OSError:
		previous = None
	try:
		_replace_atomically(guess, f"{expiry}\n")
		_replace_atomically(path, f"{expiry}\n")
	except OSError:
		_restore_marker(guess, previous)
		return False
	return True


def _restore_marker(guess: Path, previous: str | None) -> None:
	"""Put ``.guess`` back as it was, so an older guessed latch keeps reading as an unknown reset."""
	try:
		if previous is None:
			guess.unlink(missing_ok=True)
		else:
			_replace_atomically(guess, previous)
	except OSError:
		pass


def _replace_atomically(path: Path, text: str) -> None:
	"""Write ``text`` via an O_EXCL temp file + ``os.replace``: a planted symlink at ``path`` is replaced, never followed."""
	fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f"{path.name}.tmp.")
	try:
		with os.fdopen(fd, "w") as handle:
			handle.write(text)
		os.replace(tmp, path)
	except BaseException:
		Path(tmp).unlink(missing_ok=True)
		raise
