#!/bin/bash
# Runnable check for the orchestrator's worker -> judge -> push loop, with docker and curl replaced by stubs.
# Round 1 is REFUTED, round 2 is VERIFIED: expects two judge files, exit 0, verdict VERIFIED, rounds 2.
# Also checks the fail-closed paths: a judge with no verdict exits 6, a REFUTED last round exits 5.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; t=$(mktemp -d "${TMPDIR:-/tmp}/factory-test.XXXXXX"); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/secrets" "$t/runs"
for f in keycard_client_id keycard_client_secret github_token openai_key; do echo "dummy-$f" > "$t/secrets/$f"; done
git init -q --bare "$t/remote.git"; git clone -q "$t/remote.git" "$t/seed" 2>/dev/null
( cd "$t/seed" && echo hi > README.md && git add . && git -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -qm init && git push -q origin HEAD:main )
cat > "$t/bin/curl" <<'C'
#!/bin/sh
[ -t 0 ] || cat >/dev/null
echo '{"access_token":"stub-token"}'
C
cat > "$t/bin/docker" <<'D'
#!/bin/bash
# Stub: emulates the three entrypoint modes on the host-side mounts. $STUB_VERDICTS lists the verdict per judge round.
case "$1" in info) exit 0;; image) echo sha256:stub; exit 0;; ps) exit 0;; rm|stop) exit 0;; esac
set -e; mode= work= jwork= args=()
while [ $# -gt 0 ]; do case "$1" in
  -e) case "$2" in MODE=*) mode=${2#MODE=};; *) export "$2";; esac; shift 2;;
  -v) case "$2" in *:/work) work=${2%%:*};; *:/src:ro) src=${2%%:*};; *:/out) out=${2%%:*};; esac; shift 2;;
  --name|--label|--tmpfs|--memory|--cpus|--pids-limit|--security-opt) shift 2;;
  -*) shift;; *) args+=("$1"); shift;; esac; done
IFS= read -r secret; echo "stub $mode secret=$secret"
case "$mode" in
  work) cd "$work"; git checkout -q "factory/$TASK_ID" 2>/dev/null || git checkout -qb "factory/$TASK_ID" "origin/$BASE_BRANCH"
        [ "${STUB_WORK_IDLE_ROUND:-0}" = "$(git rev-list --count "origin/$BASE_BRANCH..HEAD" | xargs -I{} expr {} + 1)" ] && exit 0
        [ "${STUB_WORK_FAIL_ROUND:-0}" = "$(git rev-list --count "origin/$BASE_BRANCH..HEAD" | xargs -I{} expr {} + 1)" ] && exit 7
        echo "${args[0]}" >> work.log; git add -A; git -c commit.gpgsign=false -c user.name=w -c user.email=w@w commit -qm "round";;
  judge) n=$(cat "$STUB_STATE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STUB_STATE"
         v=$(echo "$STUB_VERDICTS" | cut -d, -f$n)
         [ "$HEAD_SHA" = "$(git -C "$src" rev-parse "refs/heads/factory/$TASK_ID")" ] || { echo "stub: HEAD_SHA mismatch" >&2; exit 9; }
         # NONE: a judge that fails after something (the worker, say) preseeded a passing verdict; it must not count.
         [ "$v" = NONE ] && { echo 'VERDICT: VERIFIED' > "$out/verdict.md"; exit 1; }
         printf 'finding %d: fix it (file.js:1)\nVERDICT: %s\n\n' "$n" "$v" > "$out/verdict.md";;
  push) [ -n "${HEAD_SHA:-}" ] && [ -n "${REPO_URL:-}" ] || exit 9; exit 0;;
esac
D
chmod +x "$t/bin/"*
run() {  # run <task_id> <verdicts> -> prints exit status
  echo "{\"repo\":\"$t/remote.git\",\"base_branch\":\"main\",\"task_id\":\"$1\",\"instructions\":\"do the thing\"}" > "$t/$1.json"
  rm -f "$t/state"; set +e
  PATH="$t/bin:$PATH" STUB_STATE="$t/state" STUB_VERDICTS="$2" FACTORY_SECRETS_DIR="$t/secrets" FACTORY_ALLOW_DIRTY=1 \
    "$here/factory" run "$t/$1.json" >"$t/$1.out" 2>&1; rc=$?; set -e
  echo "$rc"
}
check() { [ "$1" = "$2" ] || { echo "FAIL: $3: got '$1' want '$2'"; cat "$t/"*.out; echo "--- log:"; jq -r "select(.event.type==\"text\" or .event.type==\"factory\") | .event.text" "$m/log.jsonl" | tail -15; exit 1; }; }
runs="$here/runs"
rc=$(run t1 "REFUTED,VERIFIED"); m=$(ls -d "$runs"/*-t1 | tail -1)
check "$rc" 0 "t1 exit"; check "$(jq -r .judge.verdict "$m/manifest.json")" VERIFIED "t1 verdict"; check "$(jq -r .judge.rounds "$m/manifest.json")" 2 "t1 rounds"
check "$(ls "$m" | grep -c judge-)" 2 "t1 judge files"; check "$(git -C "$t/remote.git" rev-parse --verify -q refs/heads/factory/t1 >/dev/null; echo $?)" 1 "t1 stub push pushes nothing"
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
# sweep on its own queue: 010 verifies (-> done/), 020 is refuted three times (-> failed/), 030 depends on 020 and is skipped unrun (-> failed/).
q="$t/queue"; mkdir -p "$q"
task "$t/remote.git" main 010-sw-a "$body" "$q"; task "$t/remote.git" main 020-sw-b "$body" "$q"; task "$t/remote.git" factory/020-sw-b 030-sw-c "$body" "$q"
rm -f "$t/state"; set +e
PATH="$t/bin:$PATH" STUB_STATE="$t/state" STUB_VERDICTS="VERIFIED,REFUTED,REFUTED,REFUTED" FACTORY_QUEUE="$q" FACTORY_SECRETS_DIR="$t/secrets" FACTORY_ALLOW_DIRTY=1 \
  "$here/factory" sweep > "$t/sweep.out" 2>&1; rc=$?; set -e
m=$(ls -d "$runs"/*-020-sw-b | tail -1)
check "$rc" 0 "sweep exit"; check "$(ls "$q"/done)" "010-sw-a.json" "sweep done/"; check "$(ls "$q"/failed | tr '\n' ' ')" "020-sw-b.json 030-sw-c.json " "sweep failed/"
check "$(ls -d "$runs"/*-030-sw-c 2>/dev/null | wc -l | tr -d ' ')" 0 "sweep never ran the dependent of a failed task"
grep -q '030-sw-c.json: skipped, its base factory/020-sw-b failed in this sweep' "$t/sweep.out" || { echo "FAIL: sweep skip message"; cat "$t/sweep.out"; exit 1; }
check "$(grep -cE '^[0-9]{8}T[0-9]{6}Z-0[12]0-sw-[ab] ' "$t/sweep.out")" 2 "sweep report lists the two runs"
# sweep refuses a queue that fails lint, without running anything
set +e; FACTORY_QUEUE="$t/lint-bad" "$here/factory" sweep > "$t/sweep2.out" 2>&1; rc=$?; set -e
check "$rc" 1 "sweep refuses bad queue"; grep -q 'fix the queue before sweeping' "$t/sweep2.out" || { echo "FAIL: sweep refusal message"; exit 1; }
rm -rf "$runs"/*-0[12]0-sw-[ab]
rc=$(STUB_WORK_IDLE_ROUND=2 run t6 "CAVEATS"); m=$(ls -d "$runs"/*-t6 | tail -1)
check "$rc" 0 "t6 exit (caveats, idle revision ships)"; check "$(jq -r .judge.rounds "$m/manifest.json")" 1 "t6 rounds counts judged rounds only"
rm -rf "$runs"/*-t[1-8]
echo "ok: judge loop (revise, refuted, no verdict, caveats, failed revision, idle revision, redaction), lint and sweep"
