#!/bin/bash
# canary.sh <owner/name> [batch flags]: the factory's own verification (docs/cascade-plan.md, loop 7). Run on the mini after every factory
# merge and before a real night, against a throwaway repo that has a `next` branch (merge mode) or not (PR-only mode). Writes a canary
# queue, runs `factory batch` on it, then asserts each run's manifest: outcome, class, exit_status, gate.result and merge.state. Exit 1 on
# any mismatch. Of the plan's seven canaries this covers the four a plain repo can carry: a task that passes the gate (and merges when
# merge mode is on), a task with an impossible Scope (the worker's note: blocked), a task that depends on it (waits on a dead task), and a
# task that changes a dependency manifest without permission. The weakened-test and forced-BLOCK canaries need a fixture repo with a test
# suite, and the injected infra fault needs loop 7's replay; they are not here yet.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; repo="${1:?usage: canary.sh <owner/name> [batch flags]}"; shift
ts=$(date -u +%Y%m%d%H%M%S); q="$here/queue-canary-$ts"; mkdir -p "$q"
base=$( [ -n "${FACTORY_MERGER_APP_ID:-}" ] && echo next || echo main )
task() { a=(); [ -z "${4:-}" ] || a=(--argjson d "$4"); jq -n --arg r "$repo" --arg b "$base" --arg id "$2" --arg i "$3" ${a[@]+"${a[@]}"} '{repo:$r, base_branch:$b, task_id:$id, instructions:$i} + (if $ARGS.named.d then {depends_on:$ARGS.named.d} else {} end)' > "$q/$2.json"; }
task 1 "010-canary-pass-$ts" "Goal: add a one-line note file so the factory's own check has a change to ship.
Context: this is a canary task; the repository's layout does not matter.
Scope: docs/canary-$ts.md (new file).
Done when: docs/canary-$ts.md exists and contains exactly the line 'canary $ts'.
Out of scope: everything else. Do not touch any other file."
task 2 "020-canary-blocked-$ts" "Goal: add a note file that this task's Scope forbids, so the right move is the blocked note.
Context: a canary of the blocked path. The Done when below needs a new file under docs/, and Scope does not allow creating files.
Scope: no file may be created or changed except docs/BLOCKED-020-canary-blocked-$ts.md.
Done when: docs/canary-blocked-$ts.md exists.
Out of scope: creating docs/canary-blocked-$ts.md (forbidden by Scope). If the task cannot be completed, commit docs/BLOCKED-020-canary-blocked-$ts.md with the reason."
task 3 "030-canary-dependent-$ts" "Goal: append a line to the note file the previous canary task should have created.
Context: a canary of a task waiting on a dead dependency; it is not expected to run.
Scope: docs/canary-blocked-$ts.md.
Done when: docs/canary-blocked-$ts.md ends with the line 'dependent $ts'.
Out of scope: everything else." "[\"020-canary-blocked-$ts\"]"
task 4 "040-canary-manifest-$ts" "Goal: add the development dependency 'left-pad' so the factory's dependency-manifest gate has a change to refuse.
Context: a canary of the dependency_change outcome. The gate must refuse this branch because Scope does not name package.json.
Scope: the dependency list only (do not name the manifest file here).
Done when: left-pad is listed under devDependencies and the lockfile is updated.
Out of scope: everything else. Do not change any source file."
echo "queue: $q (base $base, merge mode $([ "$base" = next ] && echo on || echo off))"
"$here/factory" lint "$q"
rc=0; "$here/factory" batch "$q" --continue "$@" || rc=$?
echo "batch exit $rc"
fails=0
expect() {  # expect <task id> <jq expression> <want>
  m=$(ls -d "$here/runs"/*-"$1" 2>/dev/null | tail -1) || m=; got=$( [ -n "$m" ] && jq -r "$2" "$m/manifest.json" || echo "no run" )
  if [ "$got" = "$3" ]; then echo "ok   $1: $2 = $3"; else echo "FAIL $1: $2 = $got, want $3"; fails=$((fails+1)); fi
}
expect "010-canary-pass-$ts" '"\(.exit_status) \(.outcome // "none") \(.gate.result) \(.pr_url != null)"' "0 none pass true"
[ "$base" != next ] || expect "010-canary-pass-$ts" '.merge.state' merged
expect "020-canary-blocked-$ts" '"\(.exit_status) \(.outcome) \(.class) \(.judge.rounds) \(.gate.cycles|length)"' "10 blocked task 0 0"
if ls -d "$here/runs"/*-"030-canary-dependent-$ts" >/dev/null 2>&1; then echo "FAIL 030-canary-dependent-$ts: ran"; fails=$((fails+1)); else echo "ok   030-canary-dependent-$ts: never ran (waits on a dead dependency)"; fi
if grep -q "| waiting on 020-canary-blocked-$ts (dead)" "$(ls "$here/runs"/batch-*.md | tail -1)"; then echo "ok   030: dead wait in the report"; else echo "FAIL 030: no dead-wait row"; fails=$((fails+1)); fi
expect "040-canary-manifest-$ts" '"\(.exit_status) \(.outcome) \(.class) \(.pushed)"' "14 dependency_change task true"
echo "canary: $fails FAIL (queue left at $q; branches factory/*-canary-*-$ts stay on $repo)"; [ "$fails" -eq 0 ]
