#!/usr/bin/env bash
# risk-gate.sh <repo-dir> <base-sha> <head-sha>
# exit 0 = low (prints "low"), exit 1 = review (prints the failing rule).
# Policy is read from the BASE commit, never from the PR. Runs in CI, never by an agent, and only after the
# merge workflow has confirmed the PR's base is the default branch (a retargeted PR must not pick the script).
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

# -z everywhere: NUL-delimited paths, no quoting, no whitespace splitting (KIM-579).
# name-status -z: "status\0path\0" plus a second "path\0" for renames/copies.
while read -r -d '' status; do
  read -r -d '' p1; p2=; [[ $status == [RC]* ]] && read -r -d '' p2
  for f in "$p1" "$p2"; do
    [[ -z $f ]] && continue
    matches "$f" "${deny[@]}" && review "$f matches deny"
    matches "$f" "${allow[@]}" || review "$f outside allow"
  done
  # a rename out of the tests patterns removes a discovered test without a D status
  [[ $status == [DR]* ]] && (( ${#tests[@]} )) && matches "$p1" "${tests[@]}" && ! matches "$p2" "${tests[@]}" && review "test deleted: $p1${p2:+ (renamed to $p2)}"
done < <(git diff --name-status -z -M "$base" "$head")

while IFS=$'\t' read -r -d '' meta f; do
  case ${meta%% *} in 120000) review "symlink: $f";; 160000) review "submodule: $f";; esac
done < <(git diff --name-only -z "$base" "$head" | xargs -0 -r git ls-tree -z "$head" --)

# numstat -z: "a\td\tpath\0", or "a\td\t\0src\0dst\0" for a rename. Binary files report "-".
lines=0
while IFS=$'\t' read -r -d '' a d f; do
  [[ -z $f ]] && { read -r -d '' f; read -r -d '' f; }
  [[ $a == - ]] && review "binary: $f"
  lines=$((lines + a + d))
done < <(git diff --numstat -z "$base" "$head")
(( lines <= max )) || review "$lines changed lines > max_lines $max"

# Judge verdicts are NOT checked here: any PR-added workflow can post a factory/judge-* status, so the merge
# workflow verifies the judge's HMAC signature in its own step, with the key that this script must never see.
echo low
