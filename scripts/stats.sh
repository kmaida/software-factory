#!/usr/bin/env bash
# stats.sh <owner/repo> — trailing 30d: factory PRs merged, and revert PRs. Run by hand.
# ponytail: "zero human intervention" approximated as merged-by-the-factory-App; refine when the number matters.
set -euo pipefail
repo=$1; since=$(date -v-30d +%F 2>/dev/null || date -d '30 days ago' +%F)
gh pr list -R "$repo" --state merged --label factory --search "merged:>=$since" --json number,mergedBy \
  --jq '"merged factory PRs: \(length)\nmerged by factory app: \([.[]|select(.mergedBy.login|test("\\[bot\\]$"))]|length)"'
gh pr list -R "$repo" --state merged --search "merged:>=$since Revert in:title" --json number --jq '"revert PRs: \(length)"'
