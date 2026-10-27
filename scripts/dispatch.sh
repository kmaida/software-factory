#!/bin/bash
# One factory sweep: deterministic preflight, then the dispatch skill. The LaunchAgent and the by-hand command
# both run this under keycard agent exec, so GH_TOKEN and LINEAR_TOKEN are brokered in and no local process
# holds a credential:
#
#   keycard agent exec --config keycard.toml --zone "$KEYCARD_ZONE" -- scripts/dispatch.sh
#
# Exit 1 with the reason on stderr when a precondition fails (no registry, not under keycard agent exec, a
# registered Linear project cannot be read). A sweep that cannot read its queue must fail, not report
# "nothing to do". Otherwise exits with claude's own status.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "dispatch: $*" >&2; exit 1; }

[[ -f ~/.factory/registry.json ]] || fail "no registry; run /factory:factory-onboard first"
[[ -n ${KEYCARD_ZONE:-} ]] || fail "KEYCARD_ZONE is not set"
[[ -n ${GH_TOKEN:-} && -n ${LINEAR_TOKEN:-} ]] \
  || fail "GH_TOKEN or LINEAR_TOKEN missing: run as keycard agent exec --config $root/keycard.toml --zone \$KEYCARD_ZONE -- $0"
mkdir -p ~/.factory/logs

for project in $(jq -r 'keys[]' ~/.factory/registry.json); do
  if ! out=$("$root/scripts/linear.sh" issues "$project" 2>&1); then
    fail "cannot read Linear project $project with the brokered token: ${out##*$'\n'}"
  fi
  echo "preflight: $project = $(jq -r '"\(.project.name): \(.issues | length) factory issue(s)"' <<<"$out")"
done

# No MCP servers: --strict-mcp-config with an empty config drops the claude.ai connectors that come with the Claude
# login (Linear among them), so the only Linear path in this process is scripts/linear.sh with the brokered token.
exec claude -p "/factory:factory-dispatch" --plugin-dir "$root" --permission-mode bypassPermissions \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}'
