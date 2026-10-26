#!/usr/bin/env bash
# risk-gate.sh <repo-dir> <base-sha> <head-sha>
# exit 0 = low (prints "low"), exit 1 = review (prints the failing rule).
# Policy is read from the BASE commit, never from the PR. Runs in CI, never by an agent.
set -euo pipefail
repo=$1 base=$2 head=$3
cd "$repo"
review() { echo "review: $*"; exit 1; }

policy=$(git show "$base:.factory/policy.json" 2>/dev/null) || review "no .factory/policy.json at base"
jq -e . <<<"$policy" >/dev/null 2>&1 || review "policy.json is not valid JSON"
[[ $(jq -r '.auto_merge' <<<"$policy") == true ]] || review "auto_merge is not true"
max=$(jq -r '.max_lines // 300' <<<"$policy")
mapfile -t allow < <(jq -r '.allow[]?' <<<"$policy")
mapfile -t deny  < <(jq -r '.deny[]?'  <<<"$policy")
mapfile -t tests < <(jq -r '.tests[]?' <<<"$policy")
(( ${#allow[@]} )) || review "policy has no allow list"

# bash [[ == ]] patterns: * matches across / (so "src/*" covers nested paths)
matches() { local f=$1; shift; local g; for g in "$@"; do [[ $f == $g ]] && return 0; done; return 1; }

while IFS=$'\t' read -r status p1 p2; do
  for f in "$p1" "${p2:-}"; do
    [[ -z $f ]] && continue
    matches "$f" "${deny[@]}" && review "$f matches deny"
    matches "$f" "${allow[@]}" || review "$f outside allow"
  done
  [[ $status == D* ]] && (( ${#tests[@]} )) && matches "$p1" "${tests[@]}" && review "test deleted: $p1"
done < <(git diff --name-status -M "$base" "$head")

while IFS=$'\t' read -r meta f; do
  case ${meta%% *} in 120000) review "symlink: $f";; 160000) review "submodule: $f";; esac
done < <(git diff --name-only "$base" "$head" | xargs -r git ls-tree "$head" --)

lines=$(git diff --numstat "$base" "$head" | awk '{a+=$1; d+=$2} END{print a+d+0}')
(( lines <= max )) || review "$lines changed lines > max_lines $max"

if [[ -n ${GITHUB_REPOSITORY:-} ]]; then
  n=$(gh api "repos/$GITHUB_REPOSITORY/commits/$head/status" \
      --jq '[.statuses[] | select(.context|startswith("factory/judge-")) | select(.state=="success") | .context] | unique | length')
  (( n >= 2 )) || review "need 2 successful factory/judge-* statuses on ${head:0:7}, have $n"
else
  echo "note: GITHUB_REPOSITORY unset, judge statuses not checked" >&2
fi
echo low
