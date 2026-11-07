#!/bin/bash
# Top GraphQL spenders over a window (dotfiles-linux-dev#918).
#   gh_spend_summary.sh [WINDOW_SECONDS=3600] [TOP_N=3]
# Reads the per-account log gh_budget_log_spend appends to; see gh_budget.sh for what is recorded.
set -u

main() {
	# shellcheck source=gh_budget.sh
	source "$(dirname "${BASH_SOURCE[0]}")/gh_budget.sh"
	gh_budget_spend_summary "$@"
}

main "$@"
