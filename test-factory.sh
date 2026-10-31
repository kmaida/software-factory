#!/bin/bash
# Runnable check for the orchestrator's worker -> judge -> push loop, with docker and curl replaced by stubs.
# Round 1 is REFUTED, round 2 is VERIFIED: expects two judge files, exit 0, verdict VERIFIED, rounds 2.
# Also checks the fail-closed paths: a judge with no verdict exits 6, a REFUTED last round exits 5.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; t=$(mktemp -d "${TMPDIR:-/tmp}/factory-test.XXXXXX")
trap 'rm -rf "$t"; [ "$(cat "$here/HALT" 2>/dev/null)" = test-factory ] && rm -f "$here/HALT"' EXIT
mkdir -p "$t/bin" "$t/secrets" "$t/runs"
for f in keycard_client_id keycard_client_secret github_token openai_key; do echo "dummy-$f" > "$t/secrets/$f"; done
git init -q --bare "$t/remote.git"; git clone -q "$t/remote.git" "$t/seed" 2>/dev/null
( cd "$t/seed" && echo hi > README.md && git add . && git -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -qm init && git push -q origin HEAD:main )
openssl genrsa 2048 2>/dev/null | openssl base64 -A > "$t/app-key.b64"   # a real key: mint_github_token signs a JWT with it
cat > "$t/bin/curl" <<'C'
#!/bin/bash
# Stub: answers by URL. GitHub App calls (installation lookup, token, PR) are real-shaped; STUB_INSTALL_404=1 makes the lookup 404.
[ -t 0 ] || cat >/dev/null
w= d= prev=; for a in "$@"; do case "$prev" in -d) d=$a;; esac; case "$a" in -w) w=1;; esac; prev=$a; done
code() { [ -n "$w" ] && printf '\n%s' "$1"; exit 0; }
for a in "$@"; do case "$a" in
  resource=urn:factory:github-app-key) echo "{\"access_token\":\"$(cat "$STUB_APP_KEY")\"}"; exit 0;;
  */users/*) if [ "${STUB_USER_FAIL:-}" = 1 ]; then printf '{"message":"Not Found"}'; code 404; else printf '{"login":"kmaida-software-factory[bot]","id":424243}'; code 200; fi;;   # the App bot user
  */installation) if [ "${STUB_INSTALL_404:-}" = 1 ]; then printf '{"message":"Not Found"}'; code 404; else printf '{"id":424242}'; code 200; fi;;
  */access_tokens) [ -z "${STUB_MINTS:-}" ] || printf '%s\n' "$d" >> "$STUB_MINTS"
     if [ -n "${STUB_MINT_FAIL_AFTER:-}" ] && [ "$(wc -l < "$STUB_MINTS")" -gt "$STUB_MINT_FAIL_AFTER" ]; then printf '{"message":"Bad credentials"}'; code 401; fi
     printf '{"token":"stub-installation-token"}'; code 201;;
  */pulls\?*) if [ "${STUB_PR_LIST:-}" = 1 ]; then printf '[{"html_url":"https://github.com/o/r/pull/9"}]'; else printf '[]'; fi; code 200;;   # GET: the open PR from this head, if any
  */pulls) [ -z "${STUB_PRS:-}" ] || printf '%s\n' "$d" >> "$STUB_PRS"; if [ "${STUB_PR_EMPTY:-}" = 1 ]; then printf '{}'; code 201; elif [ "${STUB_PR_FAIL:-}" = 1 ]; then printf '{"message":"Validation Failed","errors":[{"message":"A pull request already exists for o:factory/gh3."}]}'; code 422; else printf '{"html_url":"https://github.com/o/r/pull/1","body":"%s"}' "$(printf 'x%.0s' $(seq 2500))"; code 201; fi;;   # >2000 bytes, like a real one: the URL must still be parsed
esac; done
echo '{"access_token":"stub-token"}'
C
cat > "$t/bin/docker" <<'D'
#!/bin/bash
# Stub: emulates the three entrypoint modes on the host-side mounts. $STUB_VERDICTS lists the verdict per judge round.
case "$1" in info) exit 0;; image) echo sha256:stub; exit 0;; ps) [ "${STUB_DOCKER_PS_FAIL:-}" = 1 ] && exit 1; exit 0;; rm|stop) exit 0;; esac
set -e; mode= work= jwork= args=()
while [ $# -gt 0 ]; do case "$1" in
  -e) case "$2" in MODE=*) mode=${2#MODE=};; *) export "$2";; esac; shift 2;;
  -v) case "$2" in *:/work) work=${2%%:*};; *:/src:ro) src=${2%%:*};; *:/out) out=${2%%:*};; esac; shift 2;;
  --name|--label|--tmpfs|--memory|--cpus|--pids-limit|--security-opt) shift 2;;
  -*) shift;; *) args+=("$1"); shift;; esac; done
IFS= read -r secret; echo "stub $mode secret=$secret"
case "$mode" in
  work) cd "$work"; git checkout -q "factory/$TASK_ID" 2>/dev/null || git checkout -qb "factory/$TASK_ID" "origin/$BASE_BRANCH"
        [ "${STUB_KILL_RUN:-}" = "$TASK_ID" ] && kill -9 "$(cat "$STUB_LOCK_PID")"   # the orchestrator dies mid-run, before its cleanup
        [ "${STUB_WORK_IDLE_ROUND:-0}" = "$(git rev-list --count "origin/$BASE_BRANCH..HEAD" | xargs -I{} expr {} + 1)" ] && exit 0
        [ "${STUB_WORK_FAIL_ROUND:-0}" = "$(git rev-list --count "origin/$BASE_BRANCH..HEAD" | xargs -I{} expr {} + 1)" ] && exit 7
        echo "${args[0]}" >> work.log; git add -A; git -c commit.gpgsign=false -c user.name=w -c user.email=w@w commit -qm "round";;
  judge) n=$(cat "$STUB_STATE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STUB_STATE"
         v=$(echo "$STUB_VERDICTS" | cut -d, -f$n)
         [ "$HEAD_SHA" = "$(git -C "$src" rev-parse "refs/heads/factory/$TASK_ID")" ] || { echo "stub: HEAD_SHA mismatch" >&2; exit 9; }
         case "${args[$((${#args[@]}-1))]}" in *"## Your findings on the previous round (round $((n-1)), verdict REFUTED)"*"finding 1: fix it"*) echo "stub judge: saw previous findings";; esac
         # NONE: a judge that fails after something (the worker, say) preseeded a passing verdict; it must not count.
         [ "$v" = NONE ] && { echo 'VERDICT: VERIFIED' > "$out/verdict.md"; exit 1; }
         case "$v" in
           CRLF)   printf 'finding\r\nVERDICT: VERIFIED\r\n' > "$out/verdict.md"; exit 0;;
           DOUBLE) printf 'VERDICT: REFUTED\nVERDICT: VERIFIED\n' > "$out/verdict.md"; exit 0;;
           BIG)    { head -c 199982 /dev/zero | tr '\0' x; printf 'VERDICT: VERIFIED\n\nVERDICT: REFUTED\n'; } > "$out/verdict.md"; exit 0;;   # byte 200000 ends the first verdict
         esac
         printf 'finding %d: fix it (file.js:1)\nVERDICT: %s\n\n' "$n" "$v" > "$out/verdict.md";;
  push) [ -n "${HEAD_SHA:-}" ] && [ -n "${REPO_URL:-}" ] || exit 9
        git -C "$src" push -q "$REPO_URL" "$HEAD_SHA:refs/heads/factory/$TASK_ID"   # a chained task clones this branch as its base
        [ "$TASK_ID" = "${STUB_HALT_AFTER:-}" ] && echo test-factory > "$STUB_HALT_FILE"; exit 0;;
esac
D
chmod +x "$t/bin/"*
run() {  # run <task_id> <verdicts> -> prints exit status; RUN_REPO overrides the local bare repo (a GitHub owner/name goes through the App path)
  echo "{\"repo\":\"${RUN_REPO:-$t/remote.git}\",\"base_branch\":\"main\",\"task_id\":\"$1\",\"instructions\":\"do the thing\"}" > "$t/$1.json"
  rm -f "$t/state"; set +e
  PATH="$t/bin:$PATH" STUB_STATE="$t/state" STUB_APP_KEY="$t/app-key.b64" STUB_VERDICTS="$2" FACTORY_SECRETS_DIR="$t/secrets" FACTORY_ALLOW_DIRTY=1 \
    "$here/factory" run "$t/$1.json" >"$t/$1.out" 2>&1; rc=$?; set -e
  echo "$rc"
}
check() { [ "$1" = "$2" ] || { echo "FAIL: $3: got '$1' want '$2'"; cat "$t/"*.out; echo "--- log:"; jq -r "select(.event.type==\"text\" or .event.type==\"factory\") | .event.text" "$m/log.jsonl" | tail -15; exit 1; }; }
runs="$here/runs"
rc=$(run t1 "REFUTED,VERIFIED"); m=$(ls -d "$runs"/*-t1 | tail -1)
check "$rc" 0 "t1 exit"; check "$(jq -r .judge.verdict "$m/manifest.json")" VERIFIED "t1 verdict"; check "$(jq -r .judge.rounds "$m/manifest.json")" 2 "t1 rounds"
check "$(grep -c 'stub judge: saw previous findings' "$m/log.jsonl")" 1 "t1 round 2 judge got round 1's findings, round 1 got none"
check "$(ls "$m" | grep -c judge-)" 2 "t1 judge files"; check "$(git -C "$t/remote.git" rev-parse refs/heads/factory/t1)" "$(jq -r .final_sha "$m/manifest.json")" "t1 pushed the judged commit"
# The App bot identity reached `docker run` as git env: the stub commits with -c user.name=w, and env wins, so the pushed commit carries it.
bot='kmaida-software-factory[bot] <424243+kmaida-software-factory[bot]@users.noreply.github.com>'
check "$(git -C "$t/remote.git" log -1 --format='%an <%ae> %cn <%ce>' refs/heads/factory/t1)" "$bot $bot" "t1 commit authored and committed as the App bot"
check "$(jq -r '"\(.git_identity.name) <\(.git_identity.email)>"' "$m/manifest.json")" "$bot" "t1 git_identity in manifest"
grep -q 'Review of your previous attempt (round 1 verdict: REFUTED)' "$m/log.jsonl" || grep -q 'round 2: judge verdict VERIFIED' "$m/log.jsonl" || { echo "FAIL: t1 revision prompt/log"; exit 1; }
rc=$(run t2 "REFUTED,REFUTED,REFUTED"); m=$(ls -d "$runs"/*-t2 | tail -1)
check "$rc" 5 "t2 exit"; check "$(jq -r .judge.rounds "$m/manifest.json")" 3 "t2 rounds"; check "$(jq -r .pr_url "$m/manifest.json")" null "t2 no PR"
rc=$(run t3 "NONE"); m=$(ls -d "$runs"/*-t3 | tail -1)
check "$rc" 6 "t3 exit"; check "$(jq -r .judge.verdict "$m/manifest.json")" null "t3 verdict null"
rc=$(run t4 "CAVEATS,CAVEATS,CAVEATS"); m=$(ls -d "$runs"/*-t4 | tail -1)
check "$rc" 0 "t4 exit (caveats after last round still ships)"; check "$(jq -r .judge.verdict "$m/manifest.json")" CAVEATS "t4 verdict"
grep -q 'REDACTED' "$m/log.jsonl" || { echo "FAIL: secret not redacted"; exit 1; }
! grep -q 'stub-token\|dummy-openai_key\|dummy-github_token' "$m/log.jsonl" || { echo "FAIL: secret leaked into log"; exit 1; }
rc=$(STUB_WORK_FAIL_ROUND=2 run t5 "REFUTED,VERIFIED"); m=$(ls -d "$runs"/*-t5 | tail -1)
check "$rc" 7 "t5 exit is the failed worker's"; check "$(jq -r .final_sha "$m/manifest.json" | wc -c | tr -d ' ')" 41 "t5 branch still recorded (pushed)"; check "$(jq -r .pr_url "$m/manifest.json")" null "t5 no PR"
check "$(jq -r .judge.rounds "$m/manifest.json")" 1 "t5 rounds counts judged rounds, not the failed worker round"
# lint: a good stacked pair passes; a bad trio fails with one line per broken file (id != filename and base is a later task; missing headings).
body='Goal: g.\nContext: c.\nScope: s.\nDone when: tests pass.\nOut of scope: o.'
task() { printf '{"repo":"%s","base_branch":"%s","task_id":"%s","instructions":"%s"}\n' "$1" "$2" "$3" "$4" > "$5/$3.json"; }
mkdir -p "$t/lint-ok" "$t/lint-bad"
task o/r main 010-a "$body" "$t/lint-ok"; task o/r factory/010-a 020-b "$body" "$t/lint-ok"
printf '{"repo":"o/r","base_branch":"factory/030-c","task_id":"010-x","instructions":"%s"}\n' "$body" > "$t/lint-bad/010-a.json"
task o/r main 020-b 'Goal: g.\nDone when: y.' "$t/lint-bad"; task o/r main 030-c "$body" "$t/lint-bad"
check "$("$here/factory" lint "$t/lint-ok")" "lint ok: 2 task(s)" "lint ok"
set +e; out=$("$here/factory" lint "$t/lint-bad"); rc=$?; set -e
check "$rc" 1 "lint bad exit"; check "$(printf '%s\n' "$out" | grep -c '^0[12]0-[ab]:')" 2 "lint bad reports the two broken files"
printf '%s\n' "$out" | grep -q "010-a: task_id '010-x' is not the filename; base_branch factory/030-c is a later task in the queue" || { echo "FAIL: lint messages: $out"; exit 1; }
printf '%s\n' "$out" | grep -q "020-b: instructions need the headings" || { echo "FAIL: lint headings message: $out"; exit 1; }
# batch: a three-task chain. 020 and 030 cut their branch from the previous task's branch (the files on disk are not touched: same
# bytes after the move to done/), base_branch stays the task's own and chain_base is in the manifest, and the report has one row per task.
batch() {  # batch <queue-dir> <verdicts> [flags...] -> exit status; output in $t/batch.out
  rm -f "$t/state"; set +e
  PATH="$t/bin:$PATH" STUB_STATE="$t/state" STUB_VERDICTS="$2" FACTORY_SECRETS_DIR="$t/secrets" FACTORY_ALLOW_DIRTY=1 \
    "$here/factory" batch "$1" "${@:3}" > "$t/batch.out" 2>&1; rc=$?; set -e
  echo "$rc"
}
queue() { mkdir -p "$t/$1"; for id in "${@:2}"; do task "$t/remote.git" main "$id" "$body" "$t/$1"; done; }
moved() { ls "$t/$1" 2>/dev/null | sed -E 's/^(batch-)?[0-9]+T[0-9]+Z-//' | tr '\n' ' '; }   # filenames without the run or batch id
queue ch 010-ch-a 020-ch-b 030-ch-c; sums=$(shasum "$t/ch"/*.json | cut -d' ' -f1)
rc=$(batch "$t/ch" "VERIFIED,VERIFIED,VERIFIED")
check "$rc" 0 "chain exit"; check "$(moved ch/done)" "010-ch-a.json 020-ch-b.json 030-ch-c.json " "chain done/"; check "$(moved ch)" "done " "chain queue empty"
check "$(shasum "$t/ch"/done/*.json | cut -d' ' -f1)" "$sums" "chain task files byte-identical"
m=$(ls -d "$runs"/*-010-ch-a | tail -1); check "$(jq -r '"\(.base_branch) \(.chain_base)"' "$m/manifest.json")" "main null" "chain 010 on its own base"
m=$(ls -d "$runs"/*-020-ch-b | tail -1); check "$(jq -r '"\(.base_branch) \(.chain_base)"' "$m/manifest.json")" "main factory/010-ch-a" "chain 020 cut from the chain head, PR base its own"
m=$(ls -d "$runs"/*-030-ch-c | tail -1); check "$(jq -r .chain_base "$m/manifest.json")" "factory/020-ch-b" "chain 030 rebased"
git -C "$t/remote.git" merge-base --is-ancestor refs/heads/factory/010-ch-a refs/heads/factory/020-ch-b || { echo "FAIL: chain 020 branch not cut from 010"; exit 1; }
check "$(jq -r .base_branch "$t/ch/done/"*-020-ch-b.json)" main "chain 020 file on disk unchanged"
rep=$(ls "$runs"/batch-*.md | tail -1); check "$(grep -c '^| [0-9]' "$rep")" 3 "batch report rows"; grep -q 'factory/020-ch-b | ' "$rep" || { echo "FAIL: report chain base"; cat "$rep"; exit 1; }
grep -q '^All tasks ran\.' "$rep" && grep -q 'chain: on,' "$rep" || { echo "FAIL: report end"; cat "$rep"; exit 1; }; grep -q "^report: $rep" "$t/batch.out" || { echo "FAIL: report path not printed"; exit 1; }
[ -d "$here/.lock" ] && { echo "FAIL: batch left the lock"; exit 1; }
# chain where task two is REFUTED: 020 -> failed/, 030 never runs and stays in the queue, exit is the failing run's.
queue rf 010-rf-a 020-rf-b 030-rf-c
rc=$(batch "$t/rf" "VERIFIED,REFUTED,REFUTED,REFUTED")
check "$rc" 5 "refuted chain exit"; check "$(moved rf/done)" "010-rf-a.json " "refuted chain done/"; check "$(moved rf/failed)" "020-rf-b.json " "refuted chain failed/"
check "$(moved rf)" "030-rf-c.json done failed " "refuted chain leaves 030 queued"; check "$(ls -d "$runs"/*-030-rf-c 2>/dev/null | wc -l | tr -d ' ')" 0 "refuted chain never ran 030"
grep -q '^Stopped: 020-rf-b exited 5\. 1 task(s) left in queue\.' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: refuted report"; cat "$t/batch.out"; exit 1; }
# --max-tasks 1, --stop-at in the past (nothing runs, nothing moves), HALT written during 010's push (020 stays), --no-chain.
queue mx 010-mx-a 020-mx-b; rc=$(batch "$t/mx" "VERIFIED" --max-tasks 1)
check "$rc" 0 "max-tasks exit"; check "$(moved mx/done)" "010-mx-a.json " "max-tasks done/"; check "$(moved mx)" "020-mx-b.json done " "max-tasks leaves 020"
queue st 010-st-a; rc=$(batch "$t/st" "VERIFIED" --stop-at 00:00)
check "$rc" 0 "stop-at exit"; check "$(moved st)" "010-st-a.json " "stop-at runs nothing"; grep -q 'Stopped: --stop-at 00:00 passed' "$t/batch.out" || { echo "FAIL: stop-at message"; exit 1; }
queue ha 010-ha-a 020-ha-b; rc=$(STUB_HALT_AFTER=010-ha-a STUB_HALT_FILE="$here/HALT" batch "$t/ha" "VERIFIED,VERIFIED")
check "$rc" 0 "halt exit"; check "$(moved ha/done)" "010-ha-a.json " "halt done/"; check "$(moved ha)" "020-ha-b.json done " "halt leaves 020"
grep -q 'Stopped: halted by' "$t/batch.out" || { echo "FAIL: halt message"; cat "$t/batch.out"; exit 1; }; rm -f "$here/HALT"
queue nc 010-nc-a 020-nc-b; rc=$(batch "$t/nc" "VERIFIED,VERIFIED" --no-chain)
check "$rc" 0 "no-chain exit"; m=$(ls -d "$runs"/*-020-nc-b | tail -1); check "$(jq -r '"\(.base_branch) \(.chain_base)"' "$m/manifest.json")" "main null" "no-chain 020 on its own base"
# --continue: 020 (chained on 010) is refuted -> failed/; 030 names factory/020-sw-b as its base -> failed/ unrun; 040 bases on main
# again (after a break the chain resumes from the task's own base_branch). Exit is the last failure's. A queue that fails lint is refused.
queue sw 010-sw-a 020-sw-b 040-sw-d; task "$t/remote.git" factory/020-sw-b 030-sw-c "$body" "$t/sw"
rc=$(batch "$t/sw" "VERIFIED,REFUTED,REFUTED,REFUTED,VERIFIED" --continue)
check "$rc" 5 "continue exit"; check "$(moved sw/done)" "010-sw-a.json 040-sw-d.json " "continue done/"; check "$(moved sw/failed)" "020-sw-b.json 030-sw-c.json " "continue failed/"
check "$(ls -d "$runs"/*-030-sw-c 2>/dev/null | wc -l | tr -d ' ')" 0 "continue never ran the dependent of a failed task"
m=$(ls -d "$runs"/*-040-sw-d | tail -1); check "$(jq -r '"\(.base_branch) \(.chain_base)"' "$m/manifest.json")" "main null" "continue resumes from the task's own base"
grep -q '030-sw-c: skipped, its base factory/020-sw-b failed in this batch' "$t/batch.out" || { echo "FAIL: skip message"; cat "$t/batch.out"; exit 1; }
# --continue, chain on: 010 fails, 020 (on main) passes, 030 declares base factory/010 -> skipped although the chain would have put it on 020.
mkdir -p "$t/dd"; task "$t/remote.git" main 010-dd-a "$body" "$t/dd"; task "$t/remote.git" main 020-dd-b "$body" "$t/dd"; task "$t/remote.git" factory/010-dd-a 030-dd-c "$body" "$t/dd"
rc=$(batch "$t/dd" "REFUTED,REFUTED,REFUTED,VERIFIED" --continue)
check "$rc" 5 "declared-dependency exit"; check "$(moved dd/done)" "020-dd-b.json " "declared-dependency done/"; check "$(moved dd/failed)" "010-dd-a.json 030-dd-c.json " "declared-dependency failed/"
check "$(ls -d "$runs"/*-030-dd-c 2>/dev/null | wc -l | tr -d ' ')" 0 "declared dependency on a failed task is honoured over the chain"
# A run killed before its cleanup: the loop records the exit status it saw, so neither the manifest nor the report says "running".
queue kl 010-kl-a; rc=$(STUB_KILL_RUN=010-kl-a STUB_LOCK_PID="$here/.lock/pid" batch "$t/kl" VERIFIED); m=$(ls -d "$runs"/*-010-kl-a | tail -1)
check "$rc" 137 "killed run: batch exit"; check "$(jq -r .exit_status "$m/manifest.json")" 137 "killed run: exit_status written by the loop"; check "$(moved kl/failed)" "010-kl-a.json " "killed run: failed/"
rep=$(ls "$runs"/batch-*.md | tail -1); grep -q '010-kl-a | 137 |' "$rep" || { echo "FAIL: killed run row"; cat "$rep"; exit 1; }
rc=$(batch "$t/lint-bad" VERIFIED); check "$rc" 1 "batch refuses bad queue"; grep -q 'fix the queue before batching' "$t/batch.out" || { echo "FAIL: refusal message"; exit 1; }
find "$runs" -maxdepth 1 -newer "$t/secrets" \( -name 'batch-*.md' -o -name '*-0[0-9]0-[a-z][a-z]-[a-d]' \) -exec rm -rf {} +   # only what this test made
rc=$(STUB_WORK_IDLE_ROUND=2 run t6 "CAVEATS"); m=$(ls -d "$runs"/*-t6 | tail -1)
check "$rc" 0 "t6 exit (caveats, idle revision ships)"; check "$(jq -r .judge.rounds "$m/manifest.json")" 1 "t6 rounds counts judged rounds only"
# Verdict parsing fails closed: CRLF is normalised (else VERIFIED\r equals no verdict); two VERDICT lines, or a review the bounded
# read cut (its first 200000 bytes end in a clean VERDICT line), are no verdict. A worker that fails in round 1 has zero judged rounds.
rc=$(run t7 CRLF); m=$(ls -d "$runs"/*-t7 | tail -1); check "$rc" 0 "t7 exit (CRLF verdict)"; check "$(jq -r '"\(.judge.verdict) \(.judge.rounds)"' "$m/manifest.json")" "VERIFIED 1" "t7 verdict without \\r"
rc=$(run t8 DOUBLE); m=$(ls -d "$runs"/*-t8 | tail -1); check "$rc" 6 "t8 exit (two VERDICT lines is no verdict)"
rc=$(run t9 BIG); m=$(ls -d "$runs"/*-t9 | tail -1); check "$rc" 6 "t9 exit (review over 200000 bytes is no verdict)"; grep -q 'over 200000 bytes' "$m/log.jsonl" || { echo "FAIL: t9 oversize not logged"; exit 1; }
rc=$(STUB_WORK_FAIL_ROUND=1 run t10 VERIFIED); m=$(ls -d "$runs"/*-t10 | tail -1); check "$rc" 7 "t10 exit"; check "$(jq -r '"\(.judge.rounds) \(.judge.verdict) \(.final_sha)"' "$m/manifest.json")" "0 null null" "t10 no judge round, nothing pushed"
# The bot user lookup fails: no run (nothing cloned, nothing minted), with the HTTP status in the message.
rc=$(STUB_USER_FAIL=1 run t11 VERIFIED); m=$(ls -d "$runs"/*-t11 | tail -1); check "$rc" 1 "t11 exit (bot user lookup failed)"
grep -q 'could not resolve the App bot user kmaida-software-factory\[bot\] (GET /users returned HTTP 404)' "$t/t11.out" || { echo "FAIL: t11 message"; cat "$t/t11.out"; exit 1; }
check "$(jq -r '"\(.git_identity) \(.base_sha) \(.exit_status)"' "$m/manifest.json")" "null null 1" "t11 nothing happened after the failed lookup"
rm -rf "$runs"/*-t[0-9] "$runs"/*-t1[0-9]
# GitHub App path: the installation is looked up per repo (recorded in the manifest), the token minted from it, the PR opened; a 404 fails closed before any clone.
# git's insteadOf points the https URL at the local bare repo, so only curl is stubbed.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$t/remote.git.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/o/r.git"
rc=$(RUN_REPO=o/r STUB_MINTS="$t/mints" run gh1 VERIFIED); m=$(ls -d "$runs"/*-gh1 | tail -1)
check "$rc" 0 "gh1 exit"; check "$(jq -r .installation_id "$m/manifest.json")" 424242 "gh1 installation_id in manifest"
check "$(jq -r .pr_url "$m/manifest.json")" https://github.com/o/r/pull/1 "gh1 PR opened (URL parsed from a >2000-byte 201 body)"
# The PR mint (the last one) asks for exactly pull_requests:write + contents:read: contents:read so POST /pulls can resolve refs on a private repo, nothing that could push, approve or merge.
check "$(tail -1 "$t/mints" | jq -c '.permissions == {"pull_requests":"write","contents":"read"} and .repositories == ["r"]')" true "gh1 PR token permissions"
check "$(grep -c '"contents":"write"' "$t/mints")" 2 "gh1 clone and push mints are contents:write"
rc=$(RUN_REPO=o/r STUB_INSTALL_404=1 run gh2 VERIFIED); m=$(ls -d "$runs"/*-gh2 | tail -1)
check "$rc" 1 "gh2 exit (404 fails closed)"; grep -q 'not installed on o/r' "$t/gh2.out" || { echo "FAIL: gh2 404 message"; cat "$t/gh2.out"; exit 1; }
check "$(jq -r .installation_id "$m/manifest.json")" null "gh2 no installation recorded"; check "$(jq -r .base_sha "$m/manifest.json")" null "gh2 never cloned"
# A failed PR open exits 4 and leaves the HTTP status and body in the log and the manifest, so the operator can tell why.
rc=$(RUN_REPO=o/r STUB_PR_FAIL=1 run gh3 VERIFIED); m=$(ls -d "$runs"/*-gh3 | tail -1)
check "$rc" 4 "gh3 exit (PR open failed)"; check "$(jq -r .pr_url "$m/manifest.json")" null "gh3 no PR"
check "$(jq -r .pr_error.status "$m/manifest.json")" 422 "gh3 pr_error.status in manifest"
check "$(jq -r .pr_error.body "$m/manifest.json" | jq -r '.errors[0].message')" "A pull request already exists for o:factory/gh3." "gh3 pr_error.body in manifest"
jq -r 'select(.event.type=="factory") | .event.text' "$m/log.jsonl" | grep -q 'POST /repos/o/r/pulls failed: HTTP 422 .*already exists' || { echo "FAIL: gh3 status/body not in log"; cat "$m/log.jsonl"; exit 1; }
! grep -q 'stub-installation-token' "$m/log.jsonl" "$m/manifest.json" || { echo "FAIL: gh3 token leaked"; exit 1; }
# Chain against GitHub: 020 cuts its branch from factory/010-gc-a but both PRs are opened with base main (the task's own base_branch),
# so a chain head merged and auto-deleted while the next task runs cannot make POST /pulls 422 "base ref not found".
mkdir -p "$t/gc"; task o/r main 010-gc-a "$body" "$t/gc"; task o/r main 020-gc-b "$body" "$t/gc"
rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_PRS="$t/prs" batch "$t/gc" "VERIFIED,VERIFIED")
check "$rc" 0 "gh chain exit"; check "$(jq -r .base "$t/prs" | tr '\n' ' ')" "main main " "gh chain PRs both target main"
check "$(jq -r .head "$t/prs" | tr '\n' ' ')" "factory/010-gc-a factory/020-gc-b " "gh chain PR heads"
m=$(ls -d "$runs"/*-020-gc-b | tail -1); check "$(jq -r '"\(.base_branch) \(.chain_base)"' "$m/manifest.json")" "main factory/010-gc-a" "gh chain 020 manifest"
git -C "$t/remote.git" merge-base --is-ancestor refs/heads/factory/010-gc-a refs/heads/factory/020-gc-b || { echo "FAIL: gh chain 020 not cut from 010"; exit 1; }
# An ambiguous POST /pulls (422 "already exists", or a 201 whose body has no URL) is reconciled against the open PR from this head: exit 0, URL recorded.
rc=$(RUN_REPO=o/r STUB_PR_FAIL=1 STUB_PR_LIST=1 run gh4 VERIFIED); m=$(ls -d "$runs"/*-gh4 | tail -1)
check "$rc" 0 "gh4 exit (422 but the PR exists)"; check "$(jq -r .pr_url "$m/manifest.json")" https://github.com/o/r/pull/9 "gh4 existing PR recorded"
jq -r 'select(.event.type=="factory") | .event.text' "$m/log.jsonl" | grep -q 'HTTP 422 but an open PR from factory/gh4 exists' || { echo "FAIL: gh4 reconciliation not logged"; exit 1; }
rc=$(RUN_REPO=o/r STUB_PR_EMPTY=1 STUB_PR_LIST=1 run gh5 VERIFIED); m=$(ls -d "$runs"/*-gh5 | tail -1)
check "$rc" 0 "gh5 exit (201 without html_url, PR exists)"; check "$(jq -r .pr_url "$m/manifest.json")" https://github.com/o/r/pull/9 "gh5 PR recorded"
# The push mint is refused: the run dies with the HTTP status and message, and the manifest already holds the judge's verdict.
rc=$(RUN_REPO=o/r STUB_MINTS="$t/mints6" STUB_MINT_FAIL_AFTER=1 run gh6 VERIFIED); m=$(ls -d "$runs"/*-gh6 | tail -1)
check "$rc" 1 "gh6 exit (push mint refused)"; grep -q 'installation token for o/r (HTTP 401): Bad credentials' "$t/gh6.out" || { echo "FAIL: gh6 mint diagnostics"; cat "$t/gh6.out"; exit 1; }
check "$(jq -r '"\(.judge.verdict) \(.judge.rounds) \(.exit_status)"' "$m/manifest.json")" "VERIFIED 1 1" "gh6 judge state persisted before the failure"
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0; rm -rf "$runs"/*-gh[0-9]

# factory stop while docker is down still signals, logs and records the incident instead of dying after writing HALT.
mkdir -p "$runs/stoptest"; echo '{"ended_at":null,"exit_status":null}' > "$runs/stoptest/manifest.json"; : > "$runs/stoptest/log.jsonl"
PATH="$t/bin:$PATH" STUB_DOCKER_PS_FAIL=1 "$here/factory" stop stoptest > "$t/stop.out" 2>&1 || { echo "FAIL: stop with docker down exited $?"; cat "$t/stop.out"; exit 1; }
check "$(jq -r .exit_status "$runs/stoptest/manifest.json")" 137 "stop with docker down records the incident"; rm -f "$here/HALT"; rm -rf "$runs/stoptest"
find "$runs" -maxdepth 1 -newer "$t/secrets" \( -name 'batch-*.md' -o -name '*-0[0-9]0-[a-z][a-z]-[a-d]' \) -exec rm -rf {} +   # the GitHub-path batch cases ran after the first sweep
echo "ok: judge loop (revise, refuted, no verdict, caveats, failed revision, idle revision, redaction, CRLF/double/oversize verdicts, judged-round count, App bot commit identity and its failed lookup), lint and batch (chain, refuted chain, max-tasks, stop-at, halt, no-chain, continue, declared dependency, killed run), GitHub App (installation lookup, 404, failed PR open, PR reconciliation, refused mint, chained PRs target base_branch), stop with docker down"
