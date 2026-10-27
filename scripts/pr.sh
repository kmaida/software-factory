#!/bin/bash
# Open or update a factory pull request through the GitHub REST API (https://api.github.com) with curl.
# The worker's only GitHub client for the PR itself: `gh` cannot verify TLS inside the worker sandbox
# (Go's macOS verifier asks trustd over XPC, which the seatbelt denies: "x509: OSStatus -26276"), while
# curl and git verify against /etc/ssl/cert.pem and work through the same CONNECT proxy.
#
#   pr.sh open <owner/repo> <branch> <title> [--draft] [--base <branch>] < body
#       Finds the open PR whose head is <branch>; creates it (into --base, default: the repository's
#       default branch) or updates its title and body; makes sure it carries the `factory` label.
#       Prints the PR's URL. Idempotent: a retry runs the same command.
#
# Auth: GH_TOKEN, brokered in by `keycard agent exec --config keycard.toml` (resource urn:github:factory).
# When it is unset and keycard is on PATH, the script re-runs itself under keycard agent exec, so by-hand
# use is brokered and audited too. Any failure is exit 1 with GitHub's message on stderr; nothing is retried.
# The token is sent only in the Authorization header and never printed.
set -euo pipefail

api=https://api.github.com
here=$(cd "$(dirname "$0")" && pwd)

die() { echo "pr.sh: $*" >&2; exit 1; }
usage() { sed -n '2,12p' "$0" >&2; exit 2; }

if [[ -z ${GH_TOKEN:-} ]]; then
  [[ -z ${FACTORY_PR_REEXEC:-} ]] || die "keycard agent exec did not provide GH_TOKEN; check [[credentials.default]] in $here/../keycard.toml"
  command -v keycard >/dev/null || die "GH_TOKEN is not set and keycard is not on PATH; run under keycard agent exec --config keycard.toml"
  # shellcheck disable=SC2086
  FACTORY_PR_REEXEC=1 exec keycard agent exec --config "$here/../keycard.toml" ${KEYCARD_ZONE:+--zone "$KEYCARD_ZONE"} -- "$0" "$@"
fi

# call <method> <path> [json-body]: prints the response body, or dies with GitHub's message.
call() {
  local method=$1 path=$2 out code json
  local data=()
  [[ $# -lt 3 ]] || data=(-H 'Content-Type: application/json' --data "$3")
  out=$(curl -sS -w '\n%{http_code}' -X "$method" "$api$path" \
        -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' ${data[@]+"${data[@]}"} 2>&1) \
    || die "curl failed for $method $path: ${out##*$'\n'}"
  code=${out##*$'\n'}; json=${out%$'\n'*}
  case $code in
    2*) printf '%s\n' "$json" ;;
    401|403) die "GitHub token rejected for $method $path (HTTP $code: $(jq -r '.message // empty' <<<"$json")); check the urn:github:factory resource in Keycard" ;;
    *) die "HTTP $code from GitHub for $method $path: $(jq -r '.message // empty' <<<"$json") $(jq -c '.errors // empty' <<<"$json")" ;;
  esac
}

cmd=${1:-}; [[ $cmd == open && $# -ge 4 ]] || usage
repo=$2; branch=$3; title=$4; shift 4
[[ $repo == */* ]] || die "open: repository must be owner/repo, got '$repo'"
draft=false; base=
while [[ $# -gt 0 ]]; do
  case $1 in
    --draft) draft=true; shift ;;
    --base) [[ $# -ge 2 ]] || usage; base=$2; shift 2 ;;
    *) usage ;;
  esac
done
body=$(cat)
[[ -n $body ]] || die "open: empty PR body on stdin"
owner=${repo%%/*}

existing=$(call GET "/repos/$repo/pulls?state=open&per_page=10&head=$owner:$branch" | jq -c --arg b "$branch" 'first(.[] | select(.head.ref == $b)) // empty')
if [[ -n $existing ]]; then
  n=$(jq -r .number <<<"$existing")
  [[ $draft == false || $(jq -r .draft <<<"$existing") == true ]] || echo "pr.sh: PR #$n is already open as a regular PR; --draft only applies when creating" >&2
  pr=$(call PATCH "/repos/$repo/pulls/$n" "$(jq -n --arg t "$title" --arg b "$body" '{title: $t, body: $b}')")
else
  [[ -n $base ]] || base=$(call GET "/repos/$repo" | jq -r .default_branch)
  pr=$(call POST "/repos/$repo/pulls" \
       "$(jq -n --arg t "$title" --arg h "$branch" --arg base "$base" --arg b "$body" --argjson d "$draft" \
             '{title: $t, head: $h, base: $base, body: $b, draft: $d}')")
  n=$(jq -r .number <<<"$pr")
fi

if ! jq -e '[.labels[].name] | index("factory")' <<<"$pr" >/dev/null; then
  labels=$(call POST "/repos/$repo/issues/$n/labels" '{"labels":["factory"]}')
  jq -e '[.[].name] | index("factory")' <<<"$labels" >/dev/null \
    || die "the factory label was not applied to #$n; does the label exist in $repo? (/factory:factory-onboard creates it)"
fi
jq -r .html_url <<<"$pr"
