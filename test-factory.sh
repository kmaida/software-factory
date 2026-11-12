#!/bin/bash
# Runnable check for the orchestrator's worker -> judge -> push loop, with docker and curl replaced by stubs.
# Round 1 is REFUTED, round 2 is VERIFIED: expects two judge files, exit 0, verdict VERIFIED, rounds 2.
# Also checks the fail-closed paths: a judge with no verdict exits 6, a REFUTED last round exits 5.
set -euo pipefail
unset ${!FACTORY_*}   # hermetic: the operator's shell may export FACTORY_NOTIFY_URL or FACTORY_MAX_ROUNDS, and a case below asserts their absence
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
[ -t 0 ] || in=$(cat)
case "${in:-}" in 'url = "'*) [ "${STUB_NOTIFY_FAIL:-}" != 1 ] || exit 7; printf '%s\n' "$in" | sed -n 's/^data = "\(.*\)"$/\1/p' >> "$STUB_NOTIFY"; exit 0;; esac   # FACTORY_NOTIFY_URL: record the one-line body; STUB_NOTIFY_FAIL: the POST fails
w= d= prev=; for a in "$@"; do case "$prev" in -d) d=$a;; esac; case "$a" in -w) w=1;; esac; prev=$a; done
code() { [ -n "$w" ] && printf '\n%s' "$1"; exit 0; }
for a in "$@"; do case "$a" in
  resource=urn:factory:github-app-key|resource=urn:factory:merger-app-key) echo "{\"access_token\":\"$(cat "$STUB_APP_KEY")\"}"; exit 0;;
  */users/*) if [ "${STUB_USER_FAIL:-}" = 1 ]; then printf '{"message":"Not Found"}'; code 404; else printf '{"login":"kmaida-software-factory[bot]","id":424243}'; code 200; fi;;   # the App bot user
  */installation) if [ "${STUB_INSTALL_404:-}" = 1 ]; then printf '{"message":"Not Found"}'; code 404; else printf '{"id":424242}'; code 200; fi;;
  */access_tokens) [ -z "${STUB_MINTS:-}" ] || printf '%s\n' "$d" >> "$STUB_MINTS"
     [ -z "${STUB_ISS:-}" ] || printf '%s\n' "$in" | sed -n 's/^header = "Authorization: Bearer [^.]*\.\([^.]*\)\..*/\1/p' | tr '_-' '/+' | jq -Rr '@base64d | fromjson | .iss' >> "$STUB_ISS"   # which App signed the JWT
     if [ -n "${STUB_MINT_FAIL_AFTER:-}" ] && [ "$(wc -l < "$STUB_MINTS")" -gt "$STUB_MINT_FAIL_AFTER" ]; then printf '{"message":"Bad credentials"}'; code 401; fi
     printf '{"token":"stub-installation-token"}'; code 201;;
  */pulls\?state=all\&head=*) h=${a##*head=}; h=${h#*:factory/}   # the dependency check: STUB_MERGED / STUB_OPEN list ids (merged into STUB_MERGED_BASE, default main); anything else has no PR; STUB_PULLS_FAIL: HTTP 502
     [ "${STUB_PULLS_FAIL:-}" != 1 ] || { printf '{"message":"Server Error"}'; code 502; }
     case " ${STUB_MERGED:-} " in *" $h "*) printf '[{"state":"closed","merged_at":"2026-11-02T01:00:00Z","base":{"ref":"%s"},"html_url":"https://github.com/o/r/pull/7"}]' "${STUB_MERGED_BASE:-main}"; code 200;; esac
     case " ${STUB_OPEN:-} " in *" $h "*) printf '[{"state":"open","merged_at":null,"base":{"ref":"main"},"html_url":"https://github.com/o/r/pull/8"}]'; code 200;; esac
     printf '[]'; code 200;;
  */search/issues\?*) [ "${STUB_SEARCH_FAIL:-}" != 1 ] || { printf '{"message":"API rate limit exceeded"}'; code 403; }   # STUB_REVERTED lists ids whose exact `Revert "factory: <id>"` PR is merged; the phrase search also returns prefix matches, as GitHub does
     items=; for i in ${STUB_REVERTED:-}; do case "$a" in *"$i"*) items="$items{\"title\":\"Revert \\\"factory: $i\\\"\"},";; esac; done
     printf '{"total_count":%d,"items":[%s]}' "$(printf '%s' "$items" | tr -cd '{' | wc -c)" "${items%,}"; code 200;;
  */compare/main...next) printf '{"status":"ahead","ahead_by":%s,"files":[{"additions":%s,"deletions":0}]}' "${STUB_AHEAD:-1}" "${STUB_LINES:-10}"; code 200;;   # the accumulation cap's view of next...main
  */compare/next...main) printf '{"status":"%s"}' "${STUB_CONTAIN:-behind}"; code 200;;   # the batch's main-in-next check
  */check-runs) [ "${STUB_CHECK_FAIL:-}" != 1 ] || { printf '{"message":"Resource not accessible by integration"}'; code 403; }; printf '{"id":1,"name":"factory-gate"}'; code 201;;
  */pulls/*/merge) n=$(cat "$STUB_STATE.m" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STUB_STATE.m"   # STUB_MERGE: ok (default), fail (405), lost (200 with no answer); STUB_RC: the ruleset-check sequence
     if [ "${STUB_RC:-}" = 1 ]; then case "$d" in *"$STUB_RC_BASE"*) printf '{"message":"Head branch was modified"}'; code 409;; esac; case "$n" in 3) printf '{"sha":"m-rc","merged":true}'; code 200;; *) printf '{"message":"Required status check is missing"}'; code 405;; esac; fi   # 1: no check, 2: stale (409 above), 3: the merge, 4: on main
     case "${STUB_MERGE:-ok}" in fail) printf '{"message":"Pull Request is not mergeable"}'; code 405;; lost) printf '{}'; code 200;; *) printf '{"sha":"m1","merged":true,"message":"merged"}'; code 200;; esac;;
  */rules/branches/next) printf '[{"type":"pull_request","parameters":{}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"test"},{"context":"factory-gate","integration_id":7}]}}]'; code 200;;
  */pulls/*/reviews) printf '{"message":"Unprocessable Entity: Can not approve your own pull request"}'; code 422;;
  */pulls/[0-9]*) case "$*" in *PATCH*) printf '{"state":"closed"}'; code 200;; esac   # the PR: mergeable_state, and whether it merged after a lost answer; STUB_PR_GET_FAIL=<n>: the n-th read is a 502
     g=$(cat "$STUB_STATE.g" 2>/dev/null || echo 0); g=$((g+1)); echo $g > "$STUB_STATE.g"; [ "$g" != "${STUB_PR_GET_FAIL:-}" ] || { printf '{"message":"Server Error"}'; code 502; }
     printf '{"number":1,"mergeable_state":"%s","merged":%s,"merge_commit_sha":"m2","base":{"ref":"%s"}}' "${STUB_MERGEABLE:-clean}" "${STUB_MERGED_PR:-false}" "${STUB_PR_BASE:-main}"; code 200;;
  */pulls\?*) if [ "${STUB_PR_LIST:-}" = 1 ]; then printf '[{"html_url":"https://github.com/o/r/pull/9"}]'; else printf '[]'; fi; code 200;;   # GET: the open PR from this head, if any
  */pulls) [ -z "${STUB_PRS:-}" ] || printf '%s\n' "$d" >> "$STUB_PRS"; if [ "${STUB_PR_EMPTY:-}" = 1 ]; then printf '{}'; code 201; elif [ "${STUB_PR_FAIL:-}" = 1 ]; then printf '{"message":"Validation Failed","errors":[{"message":"A pull request already exists for o:factory/gh3."}]}'; code 422; else printf '{"html_url":"https://github.com/o/r/pull/1","body":"%s"}' "$(printf 'x%.0s' $(seq 2500))"; code 201; fi;;   # >2000 bytes, like a real one: the URL must still be parsed
esac; done
echo '{"access_token":"stub-token"}'
C
cat > "$t/bin/docker" <<'D'
#!/bin/bash
# Stub: emulates the entrypoint modes on the host-side mounts. $STUB_VERDICTS lists the verdict per judge round; $STUB_REVIEW the
# break-it review's findings per gate cycle (none, regress, preexist, unmet, invalid, many, bad, crash; default none); the verifier runs
# the real verify.js against the host mounts (STUB_VERIFY_CRASH=1: it exits 1 with no record).
case "$1" in info) exit 0;;
  image) # STUB_MERGE_PREV=<id>: once that task's branch is on the remote, a human merges it (main fast-forwards) and GitHub deletes it, before the next run's clone
         [ -z "${STUB_MERGE_PREV:-}" ] || ! git -C "$STUB_REMOTE" rev-parse -q --verify "refs/heads/factory/$STUB_MERGE_PREV" >/dev/null 2>&1 || { git -C "$STUB_REMOTE" update-ref refs/heads/main "refs/heads/factory/$STUB_MERGE_PREV"; git -C "$STUB_REMOTE" update-ref -d "refs/heads/factory/$STUB_MERGE_PREV"; }
         # STUB_ADVANCE_MAIN=<id>: once that task's branch is on the remote, an unrelated PR lands on main (adds pins.md), before the next run's clone
         if [ -n "${STUB_ADVANCE_MAIN:-}" ] && git -C "$STUB_REMOTE" rev-parse -q --verify "refs/heads/factory/$STUB_ADVANCE_MAIN" >/dev/null 2>&1 && ! git -C "$STUB_REMOTE" cat-file -e main:pins.md 2>/dev/null; then
           b=$(echo pins | git -C "$STUB_REMOTE" hash-object -w --stdin); export GIT_INDEX_FILE="$STUB_REMOTE/stub-index"; git -C "$STUB_REMOTE" read-tree main; git -C "$STUB_REMOTE" update-index --add --cacheinfo "100644,$b,pins.md"
           c=$(git -C "$STUB_REMOTE" -c user.name=h -c user.email=h@x commit-tree "$(git -C "$STUB_REMOTE" write-tree)" -p main -m pins); unset GIT_INDEX_FILE; git -C "$STUB_REMOTE" update-ref refs/heads/main "$c"; fi
         echo sha256:stub; exit 0;; ps) [ "${STUB_DOCKER_PS_FAIL:-}" = 1 ] && exit 1; exit 0;; rm|stop) exit 0;;
  network) [ "$2" != connect ] || [ -z "${STUB_NETLOG:-}" ] || echo "$*" >> "$STUB_NETLOG"; exit 0;;
  logs) n=$(cat "$STUB_LOGS" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STUB_LOGS"   # STUB_PROXY_DEAD: never listens; STUB_LOGS_FAIL=<n>: the n-th `docker logs` fails
        [ "${STUB_PROXY_DEAD:-}" = 1 ] || echo '{"listening":8888,"allow":"stub"}'; [ "$n" -ge "${STUB_LOGS_FAIL:-999}" ] && exit 1; exit 0;; esac
set -e; mode= work= jwork= net= detached= queue= args=()
while [ $# -gt 0 ]; do case "$1" in
  -e) case "$2" in MODE=*) mode=${2#MODE=};; *) export "$2";; esac; shift 2;;
  -v) case "$2" in *:/work) work=${2%%:*};; *:/src:ro) src=${2%%:*};; *:/out) out=${2%%:*};; *:/in:ro) vin=${2%%:*};; *:/verify.js:ro) vjs=${2%%:*};; *:/queue:ro) queue=${2%%:*};; esac; shift 2;;
  --network) net=$2; shift 2;;
  --name|--label|--tmpfs|--memory|--cpus|--pids-limit|--security-opt|--entrypoint) shift 2;;
  -d) detached=1; shift;;
  -*) shift;; *) args+=("$1"); shift;; esac; done
# The step's proxy (`run -d … --entrypoint node`): record its allowlist and pretend to start.
[ -z "$detached" ] || { [ -z "${STUB_ALLOW:-}" ] || echo "${ALLOW:-}" >> "$STUB_ALLOW"; echo stub-proxy; exit 0; }
IFS= read -r secret; echo "stub $mode secret=$secret net=$net proxy=${HTTPS_PROXY:-} npm=${NPM_CONFIG_IGNORE_SCRIPTS:-}/${NPM_CONFIG_BEFORE:-} model=${FACTORY_MODEL:-}/${JUDGE_MODEL:-}/${REVIEW_MODEL:-} schema=${#FINDINGS_SCHEMA}"
# The worker leaks its secret encoded and a token by shape, and ends with Claude Code's cost event. STUB_PROMPT: the prompt's task_id line is kept there.
[ "$mode" != work ] || { [ -z "${STUB_PROMPT:-}" ] || printf '%s\n' "${args[$((${#args[@]}-1))]}" | grep -m1 '^task_id:' > "$STUB_PROMPT" || true; echo "b64=$(printf '%s' "$secret" | base64) shape=sk-ant-$(printf 'x%.0s' $(seq 24))"; echo '{"type":"result","total_cost_usd":0.12,"num_turns":3,"duration_ms":100}'; }
case "$mode" in
  work) cd "$work"; git checkout -q "factory/$TASK_ID" 2>/dev/null || git checkout -qb "factory/$TASK_ID" "origin/$BASE_BRANCH"
        [ "${STUB_KILL_RUN:-}" = "$TASK_ID" ] && kill -9 "$(cat "$STUB_LOCK_PID")"   # the orchestrator dies mid-run, before its cleanup
        [ "${STUB_WORK_IDLE_ROUND:-0}" = "$(git rev-list --count "origin/$BASE_BRANCH..HEAD" | xargs -I{} expr {} + 1)" ] && exit 0
        [ "${STUB_WORK_FAIL_ROUND:-0}" = "$(git rev-list --count "origin/$BASE_BRANCH..HEAD" | xargs -I{} expr {} + 1)" ] && exit 7
        p=${args[$((${#args[@]}-1))]}
        if [[ "$p" == *"## A verification gate reproduced these findings"* ]]; then   # the fix: the regression repro is `! test -e work.log`
          case "${STUB_FIX:-}" in idle) exit 0;; nofix) echo again >> work.log;; *) rm -f work.log; echo fixed >> fixed.txt;; esac
          [ -z "${STUB_FIXES:-}" ] || printf '%s\n' "$p" | grep '^- ' >> "$STUB_FIXES"   # the facts the worker was given
        elif [ "${STUB_WORK_BLOCKED:-}" = "$TASK_ID" ]; then   # the note; STUB_NOTE: code (on top of a change), dep (beside a manifest change), deleted (written, committed, removed), dir (a directory at the note's path: not a note), replace (round 2: code, plus a replace ref that makes the real head read as a note commit), round2 (code in round 1, the note in round 2)
          r=$(git rev-list --count "origin/$BASE_BRANCH..HEAD"); case "${STUB_NOTE:-}" in code|deleted) echo x >> work.log;; replace) [ "$r" -ge 1 ] || { echo x >> work.log; git add -A; git -c commit.gpgsign=false -c user.name=w -c user.email=w@w commit -qm round; exit 0; }
            echo y >> work.log; git add -A; git -c commit.gpgsign=false -c user.name=w -c user.email=w@w commit -qm code; real=$(git rev-parse HEAD)
            mkdir -p docs; echo '# BLOCKED' > "docs/BLOCKED-$TASK_ID.md"; git add -A; git -c commit.gpgsign=false -c user.name=w -c user.email=w@w commit -qm note; git replace -f "$real" "$(git rev-parse HEAD)"; git reset -q --hard "$real"; exit 0;;   # the real head reads as the note commit through refs/replace
          dir) mkdir -p "docs/BLOCKED-$TASK_ID.md"; echo x > "docs/BLOCKED-$TASK_ID.md/x"; echo x >> work.log; git add -A; git -c commit.gpgsign=false -c user.name=w -c user.email=w@w commit -qm round; exit 0;; dep) echo x > package-lock.json;; round2) [ "$r" -ge 1 ] || { echo x >> work.log; git add -A; git -c commit.gpgsign=false -c user.name=w -c user.email=w@w commit -qm round; exit 0; };; esac
          mkdir -p docs; printf '# BLOCKED: %s\n\nno "url" column on sandboxes\nmore\n' "$TASK_ID" > "docs/BLOCKED-$TASK_ID.md"
          [ "${STUB_NOTE:-}" != deleted ] || { git add -A; git -c commit.gpgsign=false -c user.name=w -c user.email=w@w commit -qm note; git rm -q "docs/BLOCKED-$TASK_ID.md"; }
        elif [ -n "${STUB_CONFLICT:-}" ] && [ "${STUB_CONFLICT_TASK:-$TASK_ID}" = "$TASK_ID" ]; then echo worker > README.md   # STUB_CONFLICT_TASK: only that task conflicts
        elif [ -n "${STUB_WORK_DEP:-}" ]; then mkdir -p apps/wéb; echo x > apps/wéb/package-lock.json
        elif [ "${STUB_SCOPE_NOTE:-}" = "$TASK_ID" ]; then echo x >> work.log; mkdir -p docs; printf -- '- t.test.js:1: the location assertion encoded the old redirect; Done when "signed out goes to /?next=" needs the new one\n' > "docs/SCOPE-$TASK_ID.md"
        elif [ -n "${STUB_WORK_DIFF:-}" ]; then echo new > a.txt; sed -i '' 's/old/new/' t.test.js   # the code and its test change together   # a nested manifest, in a path git quotes in --name-only output
        else echo "${args[0]}" >> work.log; fi
        git add -A; git -c commit.gpgsign=false -c user.name=w -c user.email=w@w commit -qm "round";;
  judge) if [ -n "$queue" ]; then   # deep lint: the queue mounted read-only, the base at its tip. STUB_DEEP: the answer (a file), crash, or unset (every task as it is)
           [ "$HEAD_SHA" = "$(git -C "$src" rev-parse "origin/$BASE_BRANCH")" ] || { echo "stub: deep lint is not at the tip of $BASE_BRANCH" >&2; exit 9; }
           case "${args[$((${#args[@]}-1))]}" in "You review a queue of coding tasks"*"## Inputs"*"Queue directory: /queue (read-only). Tasks, in order: "*) ;; *) echo "stub: deep lint prompt" >&2; exit 9;; esac
           case "${STUB_DEEP:-}" in crash) exit 1;; "") jq -n '{tasks:[inputs | {task_id, depends_on:(.depends_on // []), hold:null}]}' "$queue"/*.json > "$out/verdict.md";; *) cp "$STUB_DEEP" "$out/verdict.md";; esac; exit 0
         fi
         case "${args[$((${#args[@]}-1))]}" in "A coding task in an autonomous software factory ended blocked"*)   # the planner (revise-prompt.md), at the blocked head, with the task and the note. STUB_REVISE: spec (default), other, bad, crash, nolint, and rewrites that add to Scope: ci (a workflow), lock (a lockfile in Markdown brackets), glob (the whole repository)
           [ "$HEAD_SHA" = "$(git -C "$src" rev-parse "refs/heads/factory/$TASK_ID")" ] || { echo "stub: planner HEAD_SHA mismatch" >&2; exit 9; }
           case "${args[$((${#args[@]}-1))]}" in *"## The task as written"*"Goal: g."*"## The agent's note, docs/BLOCKED-$TASK_ID.md"*'no "url" column on sandboxes'*) ;; *) echo "stub: planner prompt lacks the task or the note" >&2; exit 9;; esac
           sc="s, x.js"; why="Done when needs x.js; Scope lists s."; case "${STUB_REVISE:-}" in ci) sc="s, .github/workflows/ci.yml";; lock) sc="s, [package-lock.json]";; glob) sc="s, **/*";; scope:*) sc=${STUB_REVISE#scope:};; html) why="Done when <!-- needs x.js.";; esac   # scope:<text>: the rewrite's Scope; html: a reason that opens an HTML comment
           case "${STUB_REVISE:-spec}" in crash) exit 1;; bad) echo 'not json' > "$out/verdict.md";;
             other) echo '{"attribution":"other","reason":"the agent could have added the column inside Scope.","changes":"","instructions":""}' > "$out/verdict.md";;
             nolint) jq -n --arg i "$(printf 'Goal: g2.\nContext: c.\nScope: s, x.js.\nDone when: tests pass.')" '{attribution:"spec", reason:"r.", changes:"c", instructions:$i}' > "$out/verdict.md";;   # no Out of scope heading: lint refuses it
             *) jq -n --arg i "$(printf 'Goal: g2.\nContext: c.\nScope: %s.\nDone when: tests pass.\nOut of scope: o. If stuck commit docs/BLOCKED-<task_id>.md.' "$sc")" '{attribution:"spec", reason:$w, changes:"Scope: s -> Scope: s, x.js", instructions:$i}' --arg w "$why" > "$out/verdict.md";; esac; exit 0;; esac
         n=$(cat "$STUB_STATE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STUB_STATE"
         v=$(echo "$STUB_VERDICTS" | cut -d, -f$n)
         # STUB_CONFLICT=<remote>: main moves under the run, with a change that conflicts with the worker's (both edit README.md).
         [ -z "${STUB_CONFLICT:-}" ] || [ "${STUB_CONFLICT_TASK:-$TASK_ID}" != "$TASK_ID" ] || ( git clone -q "$STUB_CONFLICT" "$out/c" && cd "$out/c" && echo moved > README.md && git -c commit.gpgsign=false -c user.name=m -c user.email=m@m commit -qam moved && git push -q origin HEAD:main ) || true   # already moved on a retry's round
         [ -z "${STUB_DROP_BASE:-}" ] || git -C "$STUB_DROP_BASE" update-ref -d refs/heads/main   # STUB_DROP_BASE=<remote>: the PR target vanishes, so the base fetch fails
         [ "$HEAD_SHA" = "$(git -C "$src" rev-parse "refs/heads/factory/$TASK_ID")" ] || { echo "stub: HEAD_SHA mismatch" >&2; exit 9; }
         case "${args[$((${#args[@]}-1))]}" in *"## Facts observed by the orchestrator"*"A verification gate then reproduced these findings at $(git -C "$src" rev-parse "refs/heads/factory/$TASK_ID~1"), each by running its command:"*"- a.js:1:"*"## Claims from the previous"*) echo "stub judge: saw gate facts";; esac
         p=$(git -C "$src" rev-parse "refs/heads/factory/$TASK_ID~1"); case "${args[$((${#args[@]}-1))]}" in *"## Facts observed by the orchestrator"*"judged at $p and ended REFUTED"*"## Claims from the previous round's reviewer (round $((n-1)), verdict REFUTED)"*"about $p."*"finding 1: fix it"*) echo "stub judge: saw previous findings";; esac
         # NONE: a judge that fails after something (the worker, say) preseeded a passing verdict; it must not count.
         [ "$v" = NONE ] && { echo 'VERDICT: VERIFIED' > "$out/verdict.md"; exit 1; }
         case "$v" in
           CRLF)   printf 'finding\r\nVERDICT: VERIFIED\r\n' > "$out/verdict.md"; exit 0;;
           DOUBLE) printf 'VERDICT: REFUTED\nVERDICT: VERIFIED\n' > "$out/verdict.md"; exit 0;;
           BIG)    { head -c 199982 /dev/zero | tr '\0' x; printf 'VERDICT: VERIFIED\n\nVERDICT: REFUTED\n'; } > "$out/verdict.md"; exit 0;;   # byte 200000 ends the first verdict
         esac
         printf 'finding %d: fix it (file.js:1)\nsaw key ghs_%s and mine b64 %s\nVERDICT: %s\n\n' "$n" "$(printf 'y%.0s' $(seq 36))" "$(printf '%s' "$secret" | base64)" "$v" > "$out/verdict.md";;   # a token by shape, and the judge's own key encoded
  review) case "${args[$((${#args[@]}-1))]}" in "You are a reviewer in an autonomous software factory, with one job: decide whether a rewritten task"*"## Why it was revised"*"## The task as written"*"## The task as revised"*)   # the revision review (revise-review-prompt.md). STUB_REVREVIEW: ok (default), block, crash
           echo "stub revision review"; case "${STUB_REVREVIEW:-ok}" in crash) exit 1;; block) echo '{"blocks":[{"loc":"Done when","claim":"the rewrite drops the test for y","clause":"tests pass","repro":"true"}],"notes":[]}' > "$out/review.json";; *) echo '{"blocks":[],"notes":["fine"]}' > "$out/review.json";; esac; exit 0;; esac
         n=$(cat "$STUB_STATE.r" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STUB_STATE.r"; v=$(echo "${STUB_REVIEW:-none}" | cut -d, -f$n)
         [ "$HEAD_SHA" = "$(git -C "$src" rev-parse "refs/heads/factory/$TASK_ID")" ] || { echo "stub: review HEAD_SHA mismatch" >&2; exit 9; }
         case "${args[$((${#args[@]}-1))]}" in *"## Commits"*"Head: $HEAD_SHA"*"## Task given to the agent"*) ;; *) echo "stub: review prompt lacks the commits or the task" >&2; exit 9;; esac
         case "${args[$((${#args[@]}-1))]}" in *"Claims from the previous"*|*"VERDICT"*) echo "stub: the review saw the loop judge's findings" >&2; exit 9;; esac
         b() { printf '{"loc":"a.js:1","claim":"%s","clause":"%s","repro":"%s"}' "$1" "$2" "$3"; }
         case "$v" in
           none)     echo '{"blocks":[],"notes":["looks fine"]}' > "$out/review.json";;
           regress)  echo "{\"blocks\":[$(b 'work.log must not exist' '' '! test -e work.log')],\"notes\":[]}" > "$out/review.json";;
           preexist) echo "{\"blocks\":[$(b 'always fails' '' 'false')],\"notes\":[]}" > "$out/review.json";;
           unmet*)   echo "{\"blocks\":[$(b 'fixed.txt is missing' 'fixed exists' "test -e fixed.txt # $v")],\"notes\":[]}" > "$out/review.json";;   # fails at both until the fix writes fixed.txt; unmet1, unmet2: distinct repros
           invalid)  echo "{\"blocks\":[$(b 'passes' '' 'true'),$(b 'times out' '' 'sleep 5; exit 1'),$(b 'not found' '' 'no-such-cmd-xyz'),$(b 'base cannot run' '' 'if test -e work.log; then false; else no-such-cmd-xyz; fi'),$(b 'writes then fails' '' 'echo x > work.log; false')],\"notes\":[]}" > "$out/review.json";;
           many)     { printf '{"blocks":['; for i in $(seq 12); do [ "$i" -eq 1 ] || printf ','; b "b$i" '' 'true'; done; printf '],"notes":[]}'; } > "$out/review.json";;
           bad)      echo 'not json' > "$out/review.json";;
           crash)    exit 1;;
         esac; [ "${STUB_HALT_IN_REVIEW:-}" != 1 ] || echo test-factory > "$STUB_HALT_FILE";;   # a stop lands while the review runs
  verify) [ "${STUB_VERIFY_CRASH:-}" != 1 ] || exit 1; [ -z "$secret" ] || { echo "stub: the verifier got a secret" >&2; exit 9; }
         SRC=$src IN=$vin WORK=$work OUT=$out VERIFY_TIMEOUT_MS=4000 node "$vjs";;
  push) [ -n "${HEAD_SHA:-}" ] && [ -n "${REPO_URL:-}" ] || exit 9
        n=$(cat "$STUB_STATE.p" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STUB_STATE.p"; [ "$n" != "${STUB_PUSH_FAIL_AT:-}" ] || exit 8   # STUB_PUSH_FAIL_AT=<n>: the n-th push fails
        git -C "$src" push -q "$REPO_URL" "$HEAD_SHA:refs/heads/factory/$TASK_ID"   # a chained task clones this branch as its base
        [ "$TASK_ID" = "${STUB_HALT_AFTER:-}" ] && echo test-factory > "$STUB_HALT_FILE"; exit 0;;
esac
D
realjq=$(type -P jq)
cat > "$t/bin/jq" <<J
#!/bin/bash
# Stub: the real jq, except STUB_JQ_FAIL=<mode> fails the log pipeline's jq for that mode (its --arg m <mode>): an incomplete record.
[ -n "\${STUB_JQ_FAIL:-}" ] && [[ "\$*" == *"--arg m \$STUB_JQ_FAIL"* ]] && exit 7
exec "$realjq" "\$@"
J
chmod +x "$t/bin/"*
run() {  # run <task_id> <verdicts> -> prints exit status; RUN_REPO overrides the local bare repo (a GitHub owner/name goes through the App path); RUN_INSTR the instructions (JSON-escaped)
  echo "{\"repo\":\"${RUN_REPO:-$t/remote.git}\",\"base_branch\":\"${RUN_BASE:-main}\",\"task_id\":\"$1\",\"instructions\":\"${RUN_INSTR:-do the thing}\"}" > "$t/$1.json"
  rm -f "$t/state" "$t/state.r" "$t/state.p" "$t/state.m" "$t/state.g" "$t/allow" "$t/logs"; set +e   # FACTORY_MAX_ROUNDS=3: the verdict fixtures below are written for three rounds; one case sets 5
  PATH="$t/bin:$PATH" STUB_STATE="$t/state" STUB_ALLOW="$t/allow" STUB_NETLOG="$t/netlog" STUB_LOGS="$t/logs" STUB_PROMPT="$t/prompt" STUB_APP_KEY="$t/app-key.b64" STUB_VERDICTS="$2" FACTORY_SECRETS_DIR="$t/secrets" FACTORY_ALLOW_DIRTY=1 FACTORY_MAX_ROUNDS="${FACTORY_MAX_ROUNDS:-3}" FACTORY_REVISE="${FACTORY_REVISE:-0}" \
    "$here/factory" run "$t/$1.json" >"$t/$1.out" 2>&1; rc=$?; set -e
  echo "$rc"
}
check() { [ "$1" = "$2" ] || { echo "FAIL: $3: got '$1' want '$2'"; cat "$t/"*.out; echo "--- log:"; jq -r "select(.event.type==\"text\" or .event.type==\"factory\") | .event.text" "$m/log.jsonl" | tail -15; exit 1; }; }
runs="$here/runs"
rc=$(run t1 "REFUTED,VERIFIED"); m=$(ls -d "$runs"/*-t1 | tail -1)
check "$rc" 0 "t1 exit"; check "$(jq -r .judge.verdict "$m/manifest.json")" VERIFIED "t1 verdict"; check "$(jq -r .judge.rounds "$m/manifest.json")" 2 "t1 rounds"
check "$(grep -c 'stub judge: saw previous findings' "$m/log.jsonl")" 1 "t1 round 2 judge got round 1's findings as claims, with the judged sha as a fact; round 1 got none"
check "$(ls "$m" | grep -c judge-)" 2 "t1 judge files"; check "$(git -C "$t/remote.git" rev-parse refs/heads/factory/t1)" "$(jq -r .final_sha "$m/manifest.json")" "t1 pushed the judged commit"
# The App bot identity reached `docker run` as git env: the stub commits with -c user.name=w, and env wins, so the pushed commit carries it.
bot='kmaida-software-factory[bot] <424243+kmaida-software-factory[bot]@users.noreply.github.com>'
check "$(git -C "$t/remote.git" log -1 --format='%an <%ae> %cn <%ce>' refs/heads/factory/t1)" "$bot $bot" "t1 commit authored and committed as the App bot"
check "$(jq -r '"\(.git_identity.name) <\(.git_identity.email)>"' "$m/manifest.json")" "$bot" "t1 git_identity in manifest"
grep -q 'Review of your previous attempt (round 1 verdict: REFUTED)' "$m/log.jsonl" || grep -q 'round 2: judge verdict VERIFIED' "$m/log.jsonl" || { echo "FAIL: t1 revision prompt/log"; exit 1; }
# Egress: each step ran on the run's internal network behind its own proxy, the proxy got that step's allowlist, and its decisions are in the log.
# The proxy is reached by its network alias, never by container name: a name over 63 bytes is not a resolvable DNS label (2026-11-02: every real task id).
grep -q 'stub work secret=\[REDACTED\] net=factory-[0-9TZ]*-t1 proxy=http://proxy:8888' "$m/log.jsonl" || { echo "FAIL: t1 worker not on the run network behind its proxy alias"; grep 'stub work' "$m/log.jsonl"; exit 1; }
grep -q '^network connect --alias proxy factory-[0-9TZ]*-t1 factory-[0-9TZ]*-t1-work-1-proxy$' "$t/netlog" || { echo "FAIL: t1 proxy not aliased on the run network"; cat "$t/netlog"; exit 1; }
check "$(tr '\n' ' ' < "$t/allow")" 'api\.anthropic\.com|registry\.npmjs\.org api\.openai\.com|registry\.npmjs\.org api\.anthropic\.com|registry\.npmjs\.org api\.openai\.com|registry\.npmjs\.org github\.com api\.anthropic\.com|registry\.npmjs\.org registry\.npmjs\.org ' "t1 allowlist per step (the gate's review and verifier after the push)"
check "$(jq -r 'select(.event.type=="proxy") | .event.mode' "$m/log.jsonl" | tr '\n' ' ')" "work judge work judge push review verify " "t1 proxy record per step"
grep -q 'stub work secret=\[REDACTED\] net=[^ ]* proxy=[^ ]* npm=true/20[0-9][0-9]-[^ ]* model=claude-opus-5-5/gpt-6.1-sol/claude-opus-5-5 schema=[1-9]' "$m/log.jsonl" || { echo "FAIL: t1 npm policy, models or schema not on the docker run line"; grep 'stub work' "$m/log.jsonl"; exit 1; }
! grep -q 'max-budget\|FACTORY_BUDGET' "$m/log.jsonl" "$here/factory" "$here/Dockerfile" || { echo "FAIL: a spend cap is still wired"; exit 1; }
# Pins, cost and redaction: models in the manifest; each worker round's reported cost; the report sums them; the encoded secret
# and a token by shape are redacted in the log, and the shaped token in the judge's review is redacted in judge-<n>.md.
check "$(jq -r '"\(.model) \(.judge_model) \(.review_model) \(.image_pinned)"' "$m/manifest.json")" "claude-opus-5-5 gpt-6.1-sol claude-opus-5-5 false" "t1 models and image pin in manifest"
check "$(jq -c '.worker.rounds | map([.round, .status, .reported_cost_usd, .num_turns])' "$m/manifest.json")" "[[1,0,0.12,3],[2,0,0.12,3]]" "t1 worker rounds with cost"
check "$("$here/factory" report 1 | tail -1 | awk '{print $5}')" 0.24 "t1 report cost column"
! grep -q "$(printf '%s' stub-token | base64)" "$m/log.jsonl" || { echo "FAIL: t1 base64 of the token leaked into the log"; exit 1; }
check "$(grep -c 'b64=\[REDACTED\] shape=\[REDACTED\]' "$m/log.jsonl")" 2 "t1 encoded and shaped tokens redacted in the log"
check "$(grep -c 'saw key \[REDACTED\] and mine b64 \[REDACTED\]' "$m/judge-1.md")" 1 "t1 shaped token and the judge's encoded key redacted in the judge file"
! grep -q "ghs_yyyy\|$(printf '%s' dummy-openai_key | base64)" "$m/judge-1.md" "$m/log.jsonl" || { echo "FAIL: t1 shaped token or encoded judge key leaked"; exit 1; }
check "$(jq -r '.npm_policy.ignore_scripts' "$m/manifest.json")" true "t1 npm policy in manifest"; check "$(jq -r '.npm_policy.before' "$m/manifest.json" | cut -c1-2)" 20 "t1 npm before date in manifest"
# Image pin: without FACTORY_ALLOW_DIRTY, an image other than IMAGE_ID refuses to start (before the dirty-tree check).
set +e; out=$(PATH="$t/bin:$PATH" FACTORY_SECRETS_DIR="$t/secrets" "$here/factory" run "$t/t1.json" 2>&1); rc=$?; set -e
check "$rc" 1 "image pin exit"; case "$out" in *"is sha256:stub, not the pinned sha256:"*) ;; *) echo "FAIL: image pin message: $out"; exit 1;; esac
# Evidence: a failing log stage (jq here) in a worker or a judge round is outcome evidence_error, exit 12: nothing further runs, nothing is pushed.
rc=$(STUB_JQ_FAIL=work run e1 "VERIFIED"); m=$(ls -d "$runs"/*-e1 | tail -1)
check "$rc" 12 "e1 evidence error exit"; check "$(jq -r '"\(.outcome) \(.final_sha) \(.exit_status)"' "$m/manifest.json")" "evidence_error null 12" "e1 manifest"; check "$(grep -c 'stub judge' "$m/log.jsonl")" 0 "e1 no judge ran"
check "$(jq -c '.worker.rounds | map([.round, .status, .reported_cost_usd])' "$m/manifest.json")" "[[1,0,null]]" "e1 the round is recorded with no cost"; check "$("$here/factory" report 1 | tail -1 | awk '{print $5}')" "?" "e1 report shows unknown cost"
rc=$(STUB_JQ_FAIL=push run e3 "VERIFIED"); m=$(ls -d "$runs"/*-e3 | tail -1)   # the push may have completed before its record was lost: final_sha is kept
check "$rc" 12 "e3 evidence error exit (push step)"; check "$(jq -r '"\(.outcome) \(.pr_url) \(.pushed) \(.class)"' "$m/manifest.json")" "evidence_error null null infra" "e3 manifest: pushed unknown (null), infra"; check "$(jq -r .final_sha "$m/manifest.json")" "$(git -C "$t/remote.git" rev-parse refs/heads/factory/e3)" "e3 final_sha is the pushed commit"
rc=$(STUB_JQ_FAIL=judge run e2 "VERIFIED"); m=$(ls -d "$runs"/*-e2 | tail -1)
check "$rc" 12 "e2 evidence error exit (judge round)"; check "$(jq -r '"\(.outcome) \(.final_sha) \(.pr_url) \(.judge.rounds // 0)"' "$m/manifest.json")" "evidence_error null null 0" "e2 manifest: no push, no PR, round not counted"
# A proxy that never listens: the run fails (exit 1) before the step runs, with the proxy's output in the log. A step whose network
# record cannot be collected (the 3rd `docker logs`: readiness poll, readiness check, collection) fails the run too; the step itself ran.
rc=$(STUB_PROXY_DEAD=1 run t1p "VERIFIED"); m=$(ls -d "$runs"/*-t1p | tail -1)
check "$rc" 1 "t1p dead proxy exit"; check "$(grep -c 'stub work' "$m/log.jsonl")" 0 "t1p no step ran without its proxy"; check "$(jq -r '"\(.exit_status) \(.class) \(.pushed)"' "$m/manifest.json")" "1 infra false" "t1p manifest: a die is infra, nothing pushed (written by cleanup)"
rc=$(STUB_LOGS_FAIL=3 run t1l "VERIFIED"); m=$(ls -d "$runs"/*-t1l | tail -1)
check "$rc" 1 "t1l lost network record exit"; check "$(grep -c 'stub work' "$m/log.jsonl")" 1 "t1l the step ran"; check "$(jq -r .exit_status "$m/manifest.json")" 1 "t1l manifest"
rc=$(run t2 "REFUTED,REFUTED,REFUTED"); m=$(ls -d "$runs"/*-t2 | tail -1)
check "$rc" 5 "t2 exit"; check "$(jq -r .judge.rounds "$m/manifest.json")" 3 "t2 rounds"; check "$(jq -r .pr_url "$m/manifest.json")" null "t2 no PR"
check "$(jq -r '"\(.outcome) \(.class) \(.pushed)"' "$m/manifest.json")" "refuted task true" "t2 a refusal is the task's own failure, branch pushed"
rc=$(run t3 "NONE"); m=$(ls -d "$runs"/*-t3 | tail -1)
check "$rc" 6 "t3 exit"; check "$(jq -r .judge.verdict "$m/manifest.json")" null "t3 verdict null"; check "$(jq -r .class "$m/manifest.json")" infra "t3 no verdict is an infra failure"
rc=$(run t4 "CAVEATS,CAVEATS,CAVEATS"); m=$(ls -d "$runs"/*-t4 | tail -1)
check "$rc" 0 "t4 exit (caveats after last round still ships)"; check "$(jq -r .judge.verdict "$m/manifest.json")" CAVEATS "t4 verdict"
grep -q 'REDACTED' "$m/log.jsonl" || { echo "FAIL: secret not redacted"; exit 1; }
! grep -q 'stub-token\|dummy-openai_key\|dummy-github_token' "$m/log.jsonl" || { echo "FAIL: secret leaked into log"; exit 1; }
rc=$(STUB_WORK_FAIL_ROUND=2 run t5 "REFUTED,VERIFIED"); m=$(ls -d "$runs"/*-t5 | tail -1)
check "$rc" 7 "t5 exit is the failed worker's"; check "$(jq -r .final_sha "$m/manifest.json" | wc -c | tr -d ' ')" 41 "t5 branch still recorded (pushed)"; check "$(jq -r .pr_url "$m/manifest.json")" null "t5 no PR"
check "$(jq -r .judge.rounds "$m/manifest.json")" 1 "t5 rounds counts judged rounds, not the failed worker round"
check "$(jq -r '"\(.class) \(.pushed)"' "$m/manifest.json")" "infra true" "t5 a failed worker round is infra, the judged commit was pushed"
# Supply chain. A credential shape in the base tree: refused after the clone, before any container (exit 13, outcome credential_in_input,
# reason the file name, never its content), even when a .gitattributes marks the file binary. In the task text: refused before anything is
# minted. A changed dependency manifest (in a path git quotes) with no package.json under the task's own Scope: branch pushed, no PR, exit 14;
# neither Out of scope nor a "Scope:" line inside appended findings counts. With it under Scope, exit 0.
tok="ghp_$(printf 'a%.0s' $(seq 36))"   # built, not written: the factory's own tree must stay clean for this scan
git init -q --bare "$t/cred.git"; git clone -q "$t/remote.git" "$t/cred" 2>/dev/null
( cd "$t/cred" && printf 'GITHUB_TOKEN=%s\n' "$tok" > .env.example && echo '.env.example -diff' > .gitattributes && git add . && git -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -qm cred && git push -q "$t/cred.git" HEAD:main )
rc=$(RUN_REPO="$t/cred.git" run s1 "VERIFIED"); m=$(ls -d "$runs"/*-s1 | tail -1)
check "$rc" 13 "s1 credential in base tree exit"; check "$(jq -r '.outcome+" "+.reason+" "+(.exit_status|tostring)+" "+.class' "$m/manifest.json")" "credential_in_input .env.example 13 task" "s1 outcome, class task"
check "$(grep -c 'stub ' "$m/log.jsonl")" 0 "s1 no container ran"; ! grep -q "$tok" "$m/log.jsonl" "$m/manifest.json" || { echo "FAIL: s1 the gate leaked the token"; exit 1; }
rc=$(RUN_INSTR="Goal: use $tok." run s2 "VERIFIED"); m=$(ls -d "$runs"/*-s2 | tail -1)
check "$rc" 13 "s2 credential in task text exit"; check "$(jq -r '.outcome+" "+.reason' "$m/manifest.json")" "credential_in_input instructions" "s2 outcome"
check "$(grep -c 'stub \|token issued\|key issued\|cloned' "$m/log.jsonl")" 0 "s2 nothing issued, nothing cloned, no container"
rc=$(STUB_WORK_DEP=1 RUN_INSTR='Goal: g.\nScope: s.\nDone when: y.\nOut of scope: package.json\n\nPrevious attempt: judge REFUTED. Findings:\nScope: package.json should stay as it is' run s3 "VERIFIED"); m=$(ls -d "$runs"/*-s3 | tail -1)
check "$rc" 14 "s3 dependency change exit"; check "$(jq -r '"\(.outcome) \(.class)"' "$m/manifest.json")" "dependency_change task" "s3 outcome, class task"; check "$(jq -r .reason "$m/manifest.json" | grep -c 'package-lock.json')" 1 "s3 reason names the manifest"
check "$(jq -r .final_sha "$m/manifest.json" | wc -c | tr -d ' ')" 41 "s3 branch pushed"; check "$(jq -r .pr_url "$m/manifest.json")" null "s3 no PR"
rc=$(STUB_WORK_DEP=1 RUN_INSTR='Goal: g.\nScope: the app package.json for deps named above.\nDone when: y.' run s4 "VERIFIED"); m=$(ls -d "$runs"/*-s4 | tail -1)
check "$rc" 0 "s4 dependency change named in Scope ships"; check "$(jq -r '.outcome // "none"' "$m/manifest.json")" none "s4 no outcome"
# requeue carries both refusals forward
mkdir -p "$t/sq/failed"; cp "$t/s3.json" "$t/sq/failed/$(basename "$(ls -d "$runs"/*-s3 | tail -1)").json"; "$here/factory" requeue "$t/sq/failed/"*-s3.json >/dev/null
grep -q 'changed a dependency manifest (.*package-lock.json.*) without Scope naming package.json' "$t/sq/s3-r1.json" || { echo "FAIL: requeue dependency_change note"; cat "$t/sq/s3-r1.json"; exit 1; }
# lint: a good stacked pair passes; a bad trio fails with one line per broken file (id != filename and base is a later task; missing headings; a credential shape).
body='Goal: g.\nContext: c.\nScope: s.\nDone when: tests pass.\nOut of scope: o.'
task() { printf '{"repo":"%s","base_branch":"%s","task_id":"%s","instructions":"%s"}\n' "$1" "$2" "$3" "$4" > "$5/$3.json"; }
taskd() { printf '{"repo":"%s","base_branch":"%s","task_id":"%s","instructions":"%s","depends_on":%s}\n' "$1" "$2" "$3" "$4" "$6" > "$5/$3.json"; }   # with depends_on (a JSON list)
mkdir -p "$t/lint-ok" "$t/lint-bad"
task o/r main 010-a "$body" "$t/lint-ok"; task o/r factory/010-a 020-b "$body" "$t/lint-ok"; task o/r main 015a-c "$body" "$t/lint-ok"   # 015a: a split task
printf '{"repo":"o/r","base_branch":"factory/030-c","task_id":"010-x","instructions":"%s"}\n' "$body" > "$t/lint-bad/010-a.json"
task o/r main 020-b 'Goal: g.\nDone when: y.' "$t/lint-bad"; task o/r main 030-c "$body" "$t/lint-bad"; task o/r main 040-d "Goal: use $tok.\\nContext: c.\\nScope: s.\\nDone when: y.\\nOut of scope: o." "$t/lint-bad"
check "$("$here/factory" lint "$t/lint-ok")" "lint ok: 3 task(s)" "lint ok (including a split-task id)"
set +e; out=$("$here/factory" lint "$t/lint-bad"); rc=$?; set -e
check "$rc" 1 "lint bad exit"; check "$(printf '%s\n' "$out" | grep -c '^0[124]0-[abd]:')" 3 "lint bad reports the three broken files"
printf '%s\n' "$out" | grep -q "040-d: instructions contain something shaped like a credential" || { echo "FAIL: lint credential message: $out"; exit 1; }
printf '%s\n' "$out" | grep -q "010-a: task_id '010-x' is not the filename; base_branch factory/030-c is a later task in the queue" || { echo "FAIL: lint messages: $out"; exit 1; }
printf '%s\n' "$out" | grep -q "020-b: instructions need the headings" || { echo "FAIL: lint headings message: $out"; exit 1; }
# depends_on: an earlier task, or one in done/ or failed/, passes and the graph is printed; a later task ("reorder"), the task itself, an
# unknown id and a task of another repo are refused. Ids are compared as base ids (-r<N>, -i<N> stripped), so a dependency on 010-f is
# satisfied by failed/010-f-r1.json being known.
mkdir -p "$t/lint-dep/failed" "$t/lint-dep2"; task o/r main 010-f-r1 "$body" "$t/lint-dep/failed"; task o/r main 010-a "$body" "$t/lint-dep"
echo 'not json' > "$t/lint-dep/failed/batch-x-junk.json"   # the batch archives a malformed mid-night file here; lint must not die on it
taskd o/r main 020-b "$body" "$t/lint-dep" '["010-a","010-f"]'; taskd o/r main 030-c "$body" "$t/lint-dep" '["020-b-r1"]'
check "$("$here/factory" lint "$t/lint-dep")" "graph: 020-b <- 010-a 010-f
graph: 030-c <- 020-b
lint ok: 3 task(s)" "lint depends_on ok, graph printed"
taskd o/r main 010-a "$body" "$t/lint-dep2" '["020-b"]'; task o/r main 020-b "$body" "$t/lint-dep2"; taskd o/r main 030-c "$body" "$t/lint-dep2" '["030-c"]'
taskd o/r main 040-d "$body" "$t/lint-dep2" '["999-z"]'; task o/x main 050-e "$body" "$t/lint-dep2"; taskd o/r main 060-f "$body" "$t/lint-dep2" '["050-e"]'
set +e; out=$("$here/factory" lint "$t/lint-dep2"); rc=$?; set -e; check "$rc" 1 "lint depends_on bad exit"
printf '%s\n' "$out" | grep -q "010-a: depends_on 020-b is a later task in the queue; reorder" || { echo "FAIL: lint later dep: $out"; exit 1; }
printf '%s\n' "$out" | grep -q "030-c: depends_on 030-c is the task itself" || { echo "FAIL: lint self dep: $out"; exit 1; }
printf '%s\n' "$out" | grep -q "040-d: depends_on 999-z is not a task in this queue, done/, failed/ or held/" || { echo "FAIL: lint unknown dep: $out"; exit 1; }
printf '%s\n' "$out" | grep -q "060-f: depends_on 050-e is a task of another repo" || { echo "FAIL: lint cross-repo dep: $out"; exit 1; }
printf '{"repo":"o/r","base_branch":"main","task_id":"070-g","instructions":"%s","depends_on":["", 1]}\n' "$body" > "$t/lint-dep2/070-g.json"
printf '{"repo":"o/r","base_branch":"main","task_id":"080-h","instructions":"%s","depends_on":["010-a 020-b","*"]}\n' "$body" > "$t/lint-dep2/080-h.json"
set +e; out=$("$here/factory" lint "$t/lint-dep2"); set -e; printf '%s\n' "$out" | grep -q "070-g: not {repo" || { echo "FAIL: lint depends_on schema: $out"; exit 1; }
printf '%s\n' "$out" | grep -q "080-h: depends_on '010-a 020-b' is not a task id; depends_on '\*' is not a task id" || { echo "FAIL: lint depends_on id grammar: $out"; exit 1; }
# batch: a three-task chain. 020 and 030 cut their branch from the previous task's branch (the files on disk are not touched: same
# bytes after the move to done/), base_branch stays the task's own and chain_base is in the manifest, and the report has one row per task.
batch() {  # batch <queue-dir> <verdicts> [flags...] -> exit status; output in $t/batch.out
  rm -f "$t/state" "$t/state.r" "$t/state.p" "$t/state.m" "$t/state.g"; set +e
  PATH="$t/bin:$PATH" STUB_STATE="$t/state" STUB_VERDICTS="$2" FACTORY_SECRETS_DIR="$t/secrets" FACTORY_ALLOW_DIRTY=1 FACTORY_MAX_ROUNDS=3 FACTORY_DEEP_LINT="${FACTORY_DEEP_LINT:-0}" FACTORY_REVISE="${FACTORY_REVISE:-0}" \
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
rc=$(FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/rf" "VERIFIED,REFUTED,REFUTED,REFUTED")
check "$rc" 5 "refuted chain exit"; check "$(moved rf/done)" "010-rf-a.json " "refuted chain done/"; check "$(moved rf/failed)" "020-rf-b.json " "refuted chain failed/"
check "$(moved rf)" "030-rf-c.json done failed " "refuted chain leaves 030 queued"; check "$(ls -d "$runs"/*-030-rf-c 2>/dev/null | wc -l | tr -d ' ')" 0 "refuted chain never ran 030"
grep -q '^Stopped: 020-rf-b exited 5\. 1 task(s) left in queue\.' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: refuted report"; cat "$t/batch.out"; exit 1; }
# FACTORY_NOTIFY_URL: one line per non-zero exit (010 passed: no line), with the verdict and whether the batch went on, then one summary line.
bid=$(basename "$(ls "$runs"/batch-*.md | tail -1)" .md)
check "$(cat "$t/notify")" "$bid: 020-rf-b exited 5 (REFUTED, stopped)
$bid: done: 2 run, 0 PR(s), 1 failed. Stopped: 020-rf-b exited 5. 1 task(s) left in queue." "notify lines on stop"; rm -f "$t/notify"
# Where notifications went is printed (host only, never the path that carries the topic) and in the report header; without the URL, it says so.
grep -q '^notify: notify.test$' "$t/batch.out" && grep -q 'notify: notify.test, tasks run: 2' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: notify host not reported"; cat "$t/batch.out"; exit 1; }
! grep -q 'notify.test/hook' "$t/batch.out" "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: notify path (the secret) reached the output"; exit 1; }
grep -q '^notify: off (FACTORY_NOTIFY_URL not set)$' "$t/batch.out" && { echo "FAIL: notify reported off while set"; exit 1; }
# A POST that fails is said so on stderr (the batch goes on), so a silent night can be told from a dead webhook.
queue nf 010-nf-a; rc=$(FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" STUB_NOTIFY_FAIL=1 batch "$t/nf" "REFUTED,REFUTED,REFUTED")
check "$rc" 5 "failed POST: batch exit unchanged"; check "$(grep -c '^notify: POST failed (curl exit 7)$' "$t/batch.out")" 2 "failed POST reported once per line (task, summary)"; [ ! -e "$t/notify" ] || { echo "FAIL: failed POST recorded a body"; exit 1; }
# --max-tasks 1, --stop-at in the past (nothing runs, nothing moves), HALT written during 010's push: the gate after it is pending (exit 12,
# infra, pushed), the retry file is written for tomorrow, the batch halts before it and 020 stays. --no-chain.
queue mx 010-mx-a 020-mx-b; rc=$(batch "$t/mx" "VERIFIED" --max-tasks 1)
check "$rc" 0 "max-tasks exit"; check "$(moved mx/done)" "010-mx-a.json " "max-tasks done/"; check "$(moved mx)" "020-mx-b.json done " "max-tasks leaves 020"
queue st 010-st-a; rc=$(FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/st" "VERIFIED" --stop-at 00:00)
check "$rc" 0 "stop-at exit"; check "$(moved st)" "010-st-a.json " "stop-at runs nothing"; grep -q 'Stopped: --stop-at 00:00 passed' "$t/batch.out" || { echo "FAIL: stop-at message"; exit 1; }
check "$(sed -E 's/^batch-[0-9]+T[0-9]+Z: //' "$t/notify")" "done: 0 run, 0 PR(s), 0 failed. Stopped: --stop-at 00:00 passed. 1 task(s) left in queue." "summary line when nothing ran"; rm -f "$t/notify"
queue ha 010-ha-a 020-ha-b; rc=$(STUB_HALT_AFTER=010-ha-a STUB_HALT_FILE="$here/HALT" batch "$t/ha" "VERIFIED,VERIFIED")
check "$rc" 12 "halt exit (the gate after the push is pending)"; check "$(moved ha/failed)" "010-ha-a.json " "halt: the attempt archived (pushed, infra)"; check "$(moved ha)" "010-ha-a-i1.json 020-ha-b.json failed " "halt leaves the retry and 020 for tomorrow"
m=$(ls -d "$runs"/*-010-ha-a | tail -1); check "$(jq -r '"\(.outcome) \(.class) \(.pushed) \(.gate.cycles[0].halted)"' "$m/manifest.json")" "gate_pending infra true true" "halt: gate_pending, the cycle says halted"
grep -q 'Stopped: halted by' "$t/batch.out" || { echo "FAIL: halt message"; cat "$t/batch.out"; exit 1; }; rm -f "$here/HALT"
queue nc 010-nc-a 020-nc-b; rc=$(batch "$t/nc" "VERIFIED,VERIFIED" --no-chain)
check "$rc" 0 "no-chain exit"; m=$(ls -d "$runs"/*-020-nc-b | tail -1); check "$(jq -r '"\(.base_branch) \(.chain_base)"' "$m/manifest.json")" "main null" "no-chain 020 on its own base"
# --continue: 020 (chained on 010) is refuted -> failed/; 030 names factory/020-sw-b as its base -> failed/ unrun; 040 is cut from
# 010, the last task that passed (never from the refuted branch, never back to main). Exit is the last failure's. A queue that fails lint is refused.
queue sw 010-sw-a 020-sw-b 040-sw-d; task "$t/remote.git" factory/020-sw-b 030-sw-c "$body" "$t/sw"
rc=$(FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/sw" "VERIFIED,REFUTED,REFUTED,REFUTED,VERIFIED" --continue)
check "$rc" 5 "continue exit"; check "$(moved sw/done)" "010-sw-a.json 040-sw-d.json " "continue done/"; check "$(moved sw/failed)" "020-sw-b.json 030-sw-c.json " "continue failed/"
check "$(ls -d "$runs"/*-030-sw-c 2>/dev/null | wc -l | tr -d ' ')" 0 "continue never ran the dependent of a failed task"
m=$(ls -d "$runs"/*-040-sw-d | tail -1); check "$(jq -r '"\(.base_branch) \(.chain_base)"' "$m/manifest.json")" "main factory/010-sw-a" "continue chains from the last task that passed"
git -C "$t/remote.git" merge-base --is-ancestor refs/heads/factory/010-sw-a refs/heads/factory/040-sw-d || { echo "FAIL: 040 not cut from 010"; exit 1; }
grep -q '030-sw-c: skipped, its base factory/020-sw-b failed in this batch' "$t/batch.out" || { echo "FAIL: skip message"; cat "$t/batch.out"; exit 1; }
check "$(sed -E 's/^batch-[0-9]+T[0-9]+Z: //' "$t/notify")" "020-sw-b exited 5 (REFUTED, continuing)
done: 3 run, 0 PR(s), 1 failed. All tasks ran." "notify lines with --continue; a skipped task sends none and is not counted as run"; rm -f "$t/notify"
queue nn 010-nn-a; rc=$(STUB_NOTIFY="$t/notify" batch "$t/nn" "REFUTED,REFUTED,REFUTED"); check "$rc" 5 "no-notify exit"; [ ! -e "$t/notify" ] || { echo "FAIL: POST without FACTORY_NOTIFY_URL"; exit 1; }
grep -q '^notify: off (FACTORY_NOTIFY_URL not set)$' "$t/batch.out" && grep -q 'notify: off, tasks run: 1' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: notify off not reported"; cat "$t/batch.out"; exit 1; }
# Infra, with a branch pushed (exit 6, no verdict): the task is retried once tonight as <id>-i1, next, from the same chain base; a retry
# that passes recovers the task (exit 0, the chain goes on from the retry's branch). A retry that fails the same way is the task's own
# failure (exit 6 stands, no second retry, counted as failed). Nothing pushed (a run killed in round 1): the file stays in the queue
# under its own id. Two infra failures in a row from different tasks (a proxy that never listens) stop the batch with the queue intact.
queue ir 005-ir-z 020-ir-b; task "$t/remote.git" main 010-ir-a 'Goal: g.\nContext: c.\nScope: s.\nDone when: tests pass.\nOut of scope: o. If stuck commit docs/BLOCKED-010-ir-a.md.' "$t/ir"; rc=$(FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/ir" "VERIFIED,NONE,VERIFIED,VERIFIED")
check "$rc" 0 "infra retry: recovered, exit 0"; check "$(moved ir/failed)" "010-ir-a.json " "infra retry: the attempt is archived"; check "$(moved ir/done)" "005-ir-z.json 010-ir-a-i1.json 020-ir-b.json " "infra retry: the retry ran next and passed"
m=$(ls -d "$runs"/*-010-ir-a | tail -1); check "$(jq -r '"\(.class) \(.pushed) \(.exit_status)"' "$m/manifest.json")" "infra true 6" "infra retry: original classed infra, pushed"
m=$(ls -d "$runs"/*-010-ir-a-i1 | tail -1); check "$(jq -r .chain_base "$m/manifest.json")" "factory/005-ir-z" "infra retry: the retry is cut from the same chain base"
m=$(ls -d "$runs"/*-020-ir-b | tail -1); check "$(jq -r .chain_base "$m/manifest.json")" "factory/010-ir-a-i1" "infra retry: the chain goes on from the retry's branch"
check "$(jq -r '"\(.task_id) \(.instructions | split("docs/BLOCKED-010-ir-a-i1.md") | length)"' "$t/ir/done/"*-010-ir-a-i1.json)" "010-ir-a-i1 2" "infra retry: task_id in the retry file, and the note path in its text follows it"
check "$(sed -E 's/^batch-[0-9]+T[0-9]+Z: //' "$t/notify")" "010-ir-a exited 6 (infra: exit 6, retrying as 010-ir-a-i1)
done: 4 run, 0 PR(s), 0 failed, 1 infra. All tasks ran." "infra retry: notify names the retry; the summary counts infra apart"; rm -f "$t/notify"
# A hand-queued <id>-i1 after its base passed: the base id's standing is its last run, so the batch exits with the -i1's failure.
queue hq 010-hq-a 010-hq-a-i1; rc=$(batch "$t/hq" "VERIFIED,REFUTED,REFUTED,REFUTED" --continue); check "$rc" 5 "hand-queued -i1 failing after a pass: the later run decides the exit"
queue is 010-is-a 020-is-b; rc=$(FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/is" "NONE,NONE,VERIFIED" --continue)
check "$rc" 6 "infra retry failed the same way: exit is the task's"; check "$(moved is/failed)" "010-is-a.json 010-is-a-i1.json " "same-way retry: both attempts archived, no -i2"
check "$(moved is/done)" "020-is-b.json " "same-way retry: the next task still ran"
check "$(sed -E 's/^batch-[0-9]+T[0-9]+Z: //' "$t/notify")" "010-is-a exited 6 (infra: exit 6, retrying as 010-is-a-i1)
010-is-a-i1 exited 6 (exit 6, continuing)
done: 3 run, 0 PR(s), 1 failed, 1 infra. All tasks ran." "same-way retry: the retry's line is a task failure; counts"; rm -f "$t/notify"
grep -q '010-is-a-i1 | 6 |.*| retry failed the same way |' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: same-way retry row"; cat "$t/batch.out"; exit 1; }
queue br 010-br-a 020-br-b 030-br-c; rc=$(FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" STUB_PROXY_DEAD=1 batch "$t/br" "VERIFIED,VERIFIED,VERIFIED")
check "$rc" 1 "breaker: exit is the infra failure's"; check "$(moved br)" "010-br-a.json 020-br-b.json 030-br-c.json " "breaker: every file still in the queue"
grep -q '^Stopped: two infra failures in a row (010-br-a 020-br-b)\. 3 task(s) left in queue\.' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: breaker report"; cat "$t/batch.out"; exit 1; }
check "$(sed -E 's/^batch-[0-9]+T[0-9]+Z: //' "$t/notify" | tail -1)" "done: 2 run, 0 PR(s), 0 failed, 2 infra. Stopped: two infra failures in a row (010-br-a 020-br-b). 3 task(s) left in queue." "breaker: summary names both"; rm -f "$t/notify"
# An exit-11 conflict is infra. With no chain head it is retried once, cut from the task's own base (the branch it conflicted with), and
# the retry passes. Mid-chain it is not retried (from main the retry would drop the chain's work; from the chain it would conflict again):
# archived with the reason, the batch goes on, exit 11.
queue cf 010-cf-a; rc=$(STUB_CONFLICT="$t/remote.git" batch "$t/cf" "VERIFIED,VERIFIED")
check "$rc" 0 "conflict retry: recovered"; check "$(moved cf/done)" "010-cf-a-i1.json " "conflict retry: the retry passed"; m=$(ls -d "$runs"/*-010-cf-a | tail -1)
check "$(jq -r '"\(.outcome) \(.class)"' "$m/manifest.json")" "conflict infra" "conflict retry: original outcome"; m=$(ls -d "$runs"/*-010-cf-a-i1 | tail -1); check "$(jq -r .chain_base "$m/manifest.json")" null "conflict retry: cut from its own base"
( cd "$t/seed" && git pull -q origin main && echo hi > README.md && git -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -qam reset && git push -q origin HEAD:main )   # put main back
# depends_on in a batch (local repo, so "merged" is an ancestor test). Night 1: 020 depends on 010, which passed tonight in the chain: runs.
# Night 2: 030 depends on 010, done/ but not merged into main: waits, untouched, exit 0, counted. Merge 010 into main: night 3 runs it.
queue dq 010-dq-a; taskd "$t/remote.git" main 020-dq-b "$body" "$t/dq" '["010-dq-a"]'
rc=$(batch "$t/dq" "VERIFIED,VERIFIED"); check "$rc" 0 "deps night 1: exit"; check "$(moved dq/done)" "010-dq-a.json 020-dq-b.json " "deps night 1: a dependency that passed tonight is satisfied"
taskd "$t/remote.git" main 030-dq-c "$body" "$t/dq" '["010-dq-a"]'; rc=$(FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/dq" "VERIFIED")
check "$rc" 0 "deps night 2: a wait is not a failure"; check "$(moved dq)" "030-dq-c.json done " "deps night 2: the waiting file is untouched"; check "$(find "$runs" -maxdepth 1 -name '*-030-dq-c' -newer "$t/secrets" | wc -l | tr -d ' ')" 0 "deps night 2: never ran"
grep -q '^| - | waiting | - | - | - | - | - | waiting on 010-dq-a (open) |' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: deps waiting row"; cat "$t/batch.out"; exit 1; }
check "$(sed -E 's/^batch-[0-9]+T[0-9]+Z: //' "$t/notify")" "done: 0 run, 0 PR(s), 0 failed, 1 waiting. Nothing ran. 1 task(s) left in queue (1 waiting on a dependency)." "deps night 2: summary counts the wait, says nothing ran"; rm -f "$t/notify"
# A pruned run record (no runs/<run_id>/) makes the dependency "unknown": a wait, notified, never a verdict.
rd=$(ls -d "$runs"/*-010-dq-a | tail -1); mv "$rd" "$t/dq-a-run"; rc=$(FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/dq" "VERIFIED"); mv "$t/dq-a-run" "$rd"
check "$rc" 0 "deps unknown (pruned record): a wait"; grep -q 'waiting on 010-dq-a (unknown): no run record for 010-dq-a under' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: deps unknown row"; cat "$t/batch.out"; exit 1; }
grep -q '030-dq-c waiting on 010-dq-a (unknown): no run record' "$t/notify" || { echo "FAIL: deps unknown notify"; cat "$t/notify"; exit 1; }; rm -f "$t/notify"
( cd "$t/seed" && git fetch -q origin && git merge -q --no-edit origin/factory/010-dq-a && git push -q origin HEAD:main )
rc=$(batch "$t/dq" "VERIFIED"); check "$rc" 0 "deps night 3: exit"; check "$(moved dq/done)" "010-dq-a.json 020-dq-b.json 030-dq-c.json " "deps night 3: merged into main, the dependant runs"
( cd "$t/seed" && git reset -q --hard "$(git rev-list --max-parents=0 HEAD)" && echo hi > README.md && git add -A && git -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -qm reset --allow-empty && git push -qf origin HEAD:main )   # put main back
# --no-chain: passed tonight is not on the next task's base, so 020 waits even though 010 just passed. A dependency whose task is still in
# the queue (an infra failure left for tomorrow) is "queued": a wait, not dead. A dependency that failed with nothing queued is dead: said so,
# notified, and the batch exit is non-zero although nothing else failed after it.
queue nd 010-nd-a; taskd "$t/remote.git" main 020-nd-b "$body" "$t/nd" '["010-nd-a"]'; rc=$(batch "$t/nd" "VERIFIED" --no-chain)
check "$rc" 0 "deps no-chain: exit"; check "$(moved nd)" "020-nd-b.json done " "deps no-chain: 020 waits (010 passed but is not on main)"
queue dk 010-dk-a; taskd "$t/remote.git" main 020-dk-b "$body" "$t/dk" '["010-dk-a"]'; rc=$(STUB_WORK_FAIL_ROUND=1 batch "$t/dk" "VERIFIED,VERIFIED")
check "$rc" 7 "deps queued: exit is the infra failure's"; check "$(moved dk)" "010-dk-a.json 020-dk-b.json " "deps queued: both still in the queue"
grep -q 'waiting on 010-dk-a (queued) |' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: deps queued row"; cat "$t/batch.out"; exit 1; }
queue dz 010-dz-a; taskd "$t/remote.git" main 020-dz-b "$body" "$t/dz" '["010-dz-a"]'
rc=$(FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/dz" "REFUTED,REFUTED,REFUTED" --continue)
check "$rc" 1 "deps dead: a wait on a dead dependency is a dead task"; check "$(moved dz)" "020-dz-b.json failed " "deps dead: the file stays (a human requeues the root)"
check "$(sed -E 's/^batch-[0-9]+T[0-9]+Z: //' "$t/notify")" "010-dz-a exited 5 (REFUTED, continuing)
020-dz-b waiting on 010-dz-a (dead): nothing queued, no PR open or merged
done: 1 run, 0 PR(s), 1 failed, 1 waiting (1 on a dead dependency). All tasks ran. 1 task(s) left in queue (1 waiting on a dependency)." "deps dead: notified, counted"; rm -f "$t/notify"
# Every dependency is asked: a live wait on the first does not hide a dead second. A task whose declared base is a waiting task waits too.
queue dy 010-dy-a 015-dy-b; taskd "$t/remote.git" main 020-dy-c "$body" "$t/dy" '["015-dy-b","010-dy-a"]'; task "$t/remote.git" factory/020-dy-c 030-dy-d "$body" "$t/dy"
rc=$(batch "$t/dy" "REFUTED,REFUTED,REFUTED,VERIFIED" --continue); check "$rc" 1 "deps worst-first: dead behind an open dependency decides"
grep -q 'waiting on 010-dy-a (dead): nothing queued' "$(ls "$runs"/batch-*.md | tail -1)" && grep -q 'waiting on 020-dy-c (waiting itself)' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: deps worst-first rows"; cat "$t/batch.out"; exit 1; }
check "$(moved dy)" "020-dy-c.json 030-dy-d.json done failed " "deps worst-first: both waiters untouched"
# Deep lint (loop 1). `lint --deep` runs the judge arm once, with the queue mounted read-only and the base at its tip (the stub checks both,
# and the prompt); STUB_DEEP is the session's answer. Additions land in place under the same id, after the original text, with the host's
# paragraph and nothing else changed; an id the answer drops stays (refused, said); a hold moves the task to held/ beside its reason and the
# proposal; a supplier that runs later is held for reordering; lint knows a held task and the batch waits on it as dead. All or nothing.
deep() {  # deep <queue-dir> [answer-file|crash] -> exit status; output in $t/deep.out
  sleep 1; set +e   # a deep-lint run id is a second plus "deep-lint": two in one second would collide
  PATH="$t/bin:$PATH" STUB_DEEP="${2:-}" FACTORY_SECRETS_DIR="$t/secrets" FACTORY_ALLOW_DIRTY=1 FACTORY_REVISE="${FACTORY_REVISE:-0}" "$here/factory" lint --deep "$1" > "$t/deep.out" 2>&1; rc=$?; set -e; echo "$rc"
}
answer() { jq -n "$1" > "$t/answer-$2.json"; echo "$t/answer-$2.json"; }   # answer <jq program> <name>: the session's final message
dlm() { jq -r "$1" "$(ls -d "$runs"/*-deep-lint | tail -1)/manifest.json"; }   # the last deep-lint run's manifest
queue dl 010-dl-a 020-dl-b; taskd "$t/remote.git" main 030-dl-c "$body" "$t/dl" '["010-dl-a"]'; queue dl 040-dl-d
cp "$t/dl/020-dl-b.json" "$t/dl-020.orig"; s010=$(shasum < "$t/dl/010-dl-a.json"); s030=$(shasum < "$t/dl/030-dl-c.json")
a=$(answer '{tasks:[{task_id:"010-dl-a",depends_on:[],hold:null},{task_id:"020-dl-b",depends_on:["010-dl-a"],hold:null},
  {task_id:"030-dl-c",depends_on:[],hold:null},{task_id:"040-dl-d",prerequisites:[{need:"x",source:"020-dl-b",evidence:"y"}],depends_on:["020-dl-b","010-dl-a-r1"],hold:null}]}' dl)
rc=$(deep "$t/dl" "$a"); check "$rc" 0 "deep lint: applied"
check "$(jq -c '[.task_id, .depends_on]' "$t/dl/020-dl-b.json")" '["020-dl-b",["010-dl-a"]]' "deep lint: depends_on added in place, under the same id"
check "$(jq -r --slurpfile o "$t/dl-020.orig" '(.instructions|startswith($o[0].instructions)) and ((.instructions|ltrimstr($o[0].instructions))|test("^\n\nDeep lint \\(run [0-9TZ]+-deep-lint\\) added these to depends_on, [^\n]*runs/[0-9TZ]+-deep-lint/deep-lint.json: 010-dl-a\\.$")) and (del(.instructions,.depends_on)==($o[0]|del(.instructions)))' "$t/dl/020-dl-b.json")" true "deep lint: the text as it was, then the host's paragraph (ids only), nothing else changed"
check "$(jq -c .depends_on "$t/dl/040-dl-d.json")" '["010-dl-a-r1","020-dl-b"]' "deep lint: every supplier added"
check "$(shasum < "$t/dl/010-dl-a.json") $(shasum < "$t/dl/030-dl-c.json")" "$s010 $s030" "deep lint: a task with nothing to add, and one whose answer dropped an id, are byte-identical"
grep -q '^  refused 030-dl-c: the answer dropped 010-dl-a, which stays$' "$t/deep.out" || { echo "FAIL: deep lint refused removal not said"; cat "$t/deep.out"; exit 1; }
check "$(dlm '[.deep_lint.result, (.deep_lint.added|length), (.deep_lint.refused|length), (.deep_lint.held|length), .exit_status] | @json')" '["applied",2,1,0,0]' "deep lint: the manifest"
check "$(dlm .base_sha)" "$(git -C "$t/remote.git" rev-parse main)" "deep lint: read the base at its tip"
check "$("$here/factory" lint "$t/dl" | tail -1)" "lint ok: 4 task(s)" "deep lint: the result passes lint"
queue dh 010-dh-a 020-dh-b 030-dh-c 040-dh-d; cp "$t/dh/010-dh-a.json" "$t/dh-010.orig"
a=$(answer '{tasks:[{task_id:"010-dh-a",depends_on:[],hold:{kind:"contradiction",reason:"Done when needs x.js;\nScope lists s",proposed_instructions:"Goal: g.\nContext: c.\nScope: s, x.js.\nDone when: tests pass.\nOut of scope: o."}},
  {task_id:"020-dh-b",depends_on:["030-dh-c"],hold:null},{task_id:"030-dh-c",depends_on:["010-dh-a"],hold:null},{task_id:"040-dh-d",depends_on:[],hold:null}]}' dh)
rc=$(deep "$t/dh" "$a"); check "$rc" 0 "deep lint: holds applied"
check "$(moved dh) / $(moved dh/held)" "030-dh-c.json 040-dh-d.json held  / 010-dh-a.json 010-dh-a.proposed.json 010-dh-a.reason 020-dh-b.json 020-dh-b.proposed.json 020-dh-b.reason " "deep lint: a held task leaves the queue for held/, three files each"
cmp -s "$t/dh/held/010-dh-a.json" "$t/dh-010.orig" || { echo "FAIL: deep lint: the held file is not the task as it was"; exit 1; }
check "$(cat "$t/dh/held/010-dh-a.reason")" "contradiction: Done when needs x.js; Scope lists s" "deep lint: the reason, one line"
check "$(jq -r '"\(.task_id) \(.instructions|test("Scope: s, x.js")) \(has("depends_on"))"' "$t/dh/held/010-dh-a.proposed.json")" "010-dh-a true false" "deep lint: the proposal is the operator's to apply"
check "$(cut -c1-61 "$t/dh/held/020-dh-b.reason") $(jq -c .depends_on "$t/dh/held/020-dh-b.proposed.json")" 'ordering: relies on 030-dh-c, which is not an earlier task in ["030-dh-c"]' "deep lint: a supplier that runs later is held for reordering"
check "$(jq -c .depends_on "$t/dh/030-dh-c.json")" '["010-dh-a"]' "deep lint: a supplier held tonight is still a dependency"
check "$("$here/factory" lint "$t/dh" | head -1)" "graph: 030-dh-c <- 010-dh-a" "lint: a held task is known (a wait, not an unknown id)"
check "$(dlm '[.deep_lint.held[] | .task_id + " " + .kind] | join(", ")')" "010-dh-a contradiction, 020-dh-b ordering" "deep lint: the holds in the manifest"
# The batch: a dependency held for a human is a dead wait; the free task runs; the holds count (exit 10 each, behind tonight's failures).
rc=$(FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/dh" "VERIFIED"); check "$rc" 1 "held dependency: a dead wait decides the exit"
grep -q '^| - | waiting | - | - | - | - | - | waiting on 010-dh-a (dead): held: contradiction: Done when needs x.js; Scope lists s |' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: held dependency row"; cat "$t/batch.out"; exit 1; }
check "$(moved dh/done)" "040-dh-d.json " "held dependency: the free task ran"
check "$(tail -1 "$t/notify" | sed -E 's/^batch-[0-9]+T[0-9]+Z: //')" "done: 1 run, 0 PR(s), 0 failed, 1 waiting (1 on a dead dependency), 2 held. All tasks ran. 1 task(s) left in queue (1 waiting on a dependency), 2 held for a human (queue/held/)." "held: counted in the summary"; rm -f "$t/notify"
# unhold: the given file back under its own id, the task's held files gone, the touch recorded; refused outside held/ or over a queued file.
[ ! -e "$runs/touches.tsv" ] || cp -p "$runs/touches.tsv" "$t/touches.bak"   # the operator's record survives the test
set +e; "$here/factory" unhold "$t/dh/030-dh-c.json" >/dev/null 2>&1; rc=$?; set -e; check "$rc" 1 "unhold: refused outside held/"
"$here/factory" unhold "$t/dh/held/010-dh-a.proposed.json" > /dev/null
check "$(moved dh/held) / $(jq -r '"\(.task_id) \(.instructions|test("Scope: s, x.js"))"' "$t/dh/010-dh-a.json")" "020-dh-b.json 020-dh-b.proposed.json 020-dh-b.reason  / 010-dh-a true" "unhold: the proposal queued under its own id, its held files gone"
check "$(tail -1 "$runs/touches.tsv" | cut -f2,3) $(tail -1 "$runs/touches.tsv" | cut -f4)" "unhold	010-dh-a $(shasum -a 256 "$t/dh/010-dh-a.json" | cut -d' ' -f1)" "unhold: the touch recorded with the file's hash"
cp "$t/dh/held/020-dh-b.json" "$t/dh/020-dh-b.json"; set +e; "$here/factory" unhold "$t/dh/held/020-dh-b.json" >/dev/null 2>&1; rc=$?; set -e; check "$rc" 1 "unhold: refused over a queued file"
rm "$t/dh/020-dh-b.json"; set +e; out=$("$here/factory" unhold "$t/dh/held/020-dh-b.proposed.json" 2>&1); rc=$?; set -e   # its proposal names 030, later in the queue
check "$rc $(moved dh/held) $(ls "$t/dh"/020-dh-b.json 2>/dev/null | wc -l | tr -d ' ')" "1 020-dh-b.json 020-dh-b.proposed.json 020-dh-b.reason  0" "unhold: refused when the queue would fail lint, nothing moved"
case "$out" in *"020-dh-b: depends_on 030-dh-c is a later task in the queue; reorder"*) ;; *) echo "FAIL: unhold lint message: $out"; exit 1;; esac
mkdir "$here/.lock"; echo $$ > "$here/.lock/pid"; set +e; "$here/factory" unhold "$t/dh/held/020-dh-b.json" >/dev/null 2>&1; rc=$?; set -e; rm -rf "$here/.lock"
check "$rc $(moved dh/held)" "1 020-dh-b.json 020-dh-b.proposed.json 020-dh-b.reason " "unhold: refused while a batch holds the lock"
chmod 555 "$t/dh"; set +e; "$here/factory" unhold "$t/dh/held/020-dh-b.json" >/dev/null 2>&1; rc=$?; set -e; chmod 755 "$t/dh"
check "$rc $(moved dh/held)" "1 020-dh-b.json 020-dh-b.proposed.json 020-dh-b.reason " "unhold: a copy that fails keeps the held files"
if [ -e "$t/touches.bak" ]; then cp -p "$t/touches.bak" "$runs/touches.tsv"; else rm -f "$runs/touches.tsv"; fi
# lint reserves the proposal's name: a task id ending in .proposed would collide with held/<id>.proposed.json.
mkdir -p "$t/lint-prop"; task o/r main 010-a.proposed "$body" "$t/lint-prop"; set +e; out=$("$here/factory" lint "$t/lint-prop"); rc=$?; set -e
check "$rc" 1 "lint: .proposed reserved"; case "$out" in *"task_id must not end in .proposed"*) ;; *) echo "FAIL: lint .proposed message: $out"; exit 1;; esac
# A deep lint that dies between its renames (here: held/ cannot be created) says so: the queue may be partly changed, never "nothing changed".
queue dp 010-dp-a 020-dp-b; : > "$t/dp/held"
a=$(answer '{tasks:[{task_id:"010-dp-a",depends_on:[],hold:{kind:"contradiction",reason:"r",proposed_instructions:""}},{task_id:"020-dp-b",depends_on:[],hold:null}]}' dp)
sleep 1; rc=$(FACTORY_DEEP_LINT=1 STUB_DEEP="$a" FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/dp" "VERIFIED,VERIFIED")
check "$rc $(dlm .deep_lint.result)" "0 applying" "deep lint died while applying: recorded as applying, the night ran"
check "$(head -1 "$t/notify" | sed -E 's/^batch-[0-9]+T[0-9]+Z: //; s/run [0-9TZ]+-deep-lint/run <id>/')" "deep lint failed while applying its result (exit 1, run <id>): the queue may be partly changed (deep_lint in the manifest has the plan); the night runs on the deterministic lint" "deep lint died while applying: said so"; rm -f "$t/notify"
# All held, deep lint inside the batch: each hold notified once with its reason, a held row each, nothing ran, exit 10, never a quiet success.
queue da 010-da-a 020-da-b
a=$(answer '{tasks:[{task_id:"010-da-a",depends_on:[],hold:{kind:"human_input",reason:"docs/pins.md is blank",proposed_instructions:""}},{task_id:"020-da-b",depends_on:[],hold:{kind:"missing_prerequisite",reason:"no GET /x | for its caller",proposed_instructions:""}}]}' da)
sleep 1; rc=$(FACTORY_DEEP_LINT=1 STUB_DEEP="$a" FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/da" "VERIFIED"); check "$rc" 10 "all held: exit 10, not success"
check "$(sed -E 's/^batch-[0-9]+T[0-9]+Z: //' "$t/notify")" "010-da-a held by deep lint (human_input): docs/pins.md is blank
020-da-b held by deep lint (missing_prerequisite): no GET /x / for its caller
done: 0 run, 0 PR(s), 0 failed, 2 held. Nothing ran. 0 task(s) left in queue, 2 held for a human (queue/held/)." "all held: each hold notified, the summary says held"; rm -f "$t/notify"
rep=$(ls "$runs"/batch-*.md | tail -1); grep -q '^| - | held | - | - | - | - | - | 010-da-a (human_input): docs/pins.md is blank |$' "$rep" && grep -q 'deep lint: run [0-9TZ]*-deep-lint, 0 task(s) gained depends_on, 2 held$' "$rep" || { echo "FAIL: all held: report"; cat "$rep"; exit 1; }
# Transactional: an answer that misses a task, and one whose additions fail the deterministic lint (a supplier of another repo), change nothing,
# the hold beside it included; no held/, no staging left. A queue that fails lint never reaches the container.
queue dx 010-dx-a 020-dx-b; mkdir -p "$t/dx/done"; task o/x main 005-dx-z "$body" "$t/dx/done"; sx=$(cat "$t/dx"/*.json | shasum)
rc=$(deep "$t/dx" "$(answer '{tasks:[{task_id:"010-dx-a",depends_on:[],hold:null}]}' dx1)"); check "$rc $(dlm .deep_lint.result)" "6 invalid" "deep lint: an answer that misses a task changes nothing"
rc=$(deep "$t/dx" "$(answer '{tasks:[{task_id:"010-dx-a",depends_on:[],hold:{kind:"contradiction",reason:"r",proposed_instructions:""}},{task_id:"020-dx-b",depends_on:["005-dx-z"],hold:null}]}' dx2)")
check "$rc $(dlm .deep_lint.result)" "6 refused" "deep lint: a proposed queue that fails lint changes nothing"
grep -q '020-dx-b: depends_on 005-dx-z is a task of another repo' "$t/deep.out" || { echo "FAIL: deep lint: lint's refusal not shown"; cat "$t/deep.out"; exit 1; }
check "$(cat "$t/dx"/*.json | shasum) $(ls -A "$t/dx" | tr '\n' ' ')" "$sx 010-dx-a.json 020-dx-b.json done " "deep lint: transactional (the queue as it was, no held/, no staging)"
n0=$(ls -d "$runs"/*-deep-lint | wc -l); rc=$(deep "$t/lint-bad"); check "$rc $(ls -d "$runs"/*-deep-lint | wc -l)" "1 $n0" "deep lint: a queue that fails lint is refused before any run"
grep -q 'the queue fails lint' "$t/deep.out" || { echo "FAIL: deep lint lint refusal"; cat "$t/deep.out"; exit 1; }
# A deep lint that fails (the session crashed) changes nothing; the night runs on the deterministic lint, and the phone says so.
queue df 010-df-a; sleep 1; rc=$(FACTORY_DEEP_LINT=1 STUB_DEEP=crash FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/df" "VERIFIED")
check "$rc $(moved df/done)" "0 010-df-a.json " "deep lint failed: the task still ran"
check "$(head -1 "$t/notify" | sed -E 's/^batch-[0-9]+T[0-9]+Z: //; s/run [0-9TZ]+-deep-lint/run <id>/')" "deep lint failed (exit 6, run <id>); the night runs on the deterministic lint" "deep lint failed: notified"; rm -f "$t/notify"
grep -q 'deep lint: failed (exit 6, run [0-9TZ]*-deep-lint); deterministic lint only$' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: deep lint failure not in the report"; exit 1; }
queue cg 005-cg-z 010-cg-a; rc=$(STUB_CONFLICT="$t/remote.git" STUB_CONFLICT_TASK=010-cg-a batch "$t/cg" "VERIFIED,VERIFIED" --continue)
check "$rc" 11 "conflict mid-chain: exit"; check "$(moved cg/done)" "005-cg-z.json " "conflict mid-chain: the chain head stays"; check "$(moved cg/failed)" "010-cg-a.json " "conflict mid-chain: archived, no retry"
check "$(ls "$t/cg"/*.json 2>/dev/null | wc -l | tr -d ' ')" 0 "conflict mid-chain: no retry file"; grep -q '010-cg-a | 11 |.*| conflicts with main mid-chain; not retried' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: conflict mid-chain row"; cat "$t/batch.out"; exit 1; }
( cd "$t/seed" && git pull -q origin main && echo hi > README.md && git -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -qam reset && git push -q origin HEAD:main )   # put main back
queue nu 010-nu-a; rc=$(FACTORY_NOTIFY_URL=$'http://x"\nwrite-out=INJECTED' batch "$t/nu" VERIFIED); check "$rc" 1 "a URL that could break the curl config is refused"; check "$(moved nu)" "010-nu-a.json " "refused URL: nothing ran"
# --continue, chain on: 010 fails, 020 (on main) passes, 030 declares base factory/010 -> skipped although the chain would have put it on 020.
mkdir -p "$t/dd"; task "$t/remote.git" main 010-dd-a "$body" "$t/dd"; task "$t/remote.git" main 020-dd-b "$body" "$t/dd"; task "$t/remote.git" factory/010-dd-a 030-dd-c "$body" "$t/dd"
rc=$(batch "$t/dd" "REFUTED,REFUTED,REFUTED,VERIFIED" --continue)
check "$rc" 5 "declared-dependency exit"; check "$(moved dd/done)" "020-dd-b.json " "declared-dependency done/"; check "$(moved dd/failed)" "010-dd-a.json 030-dd-c.json " "declared-dependency failed/"
check "$(ls -d "$runs"/*-030-dd-c 2>/dev/null | wc -l | tr -d ' ')" 0 "declared dependency on a failed task is honoured over the chain"
# A run killed before its cleanup: the loop records the exit status it saw, so neither the manifest nor the report says "running".
queue kl 010-kl-a; rc=$(STUB_KILL_RUN=010-kl-a STUB_LOCK_PID="$here/.lock/pid" batch "$t/kl" VERIFIED); m=$(ls -d "$runs"/*-010-kl-a | tail -1)
check "$rc" 137 "killed run: batch exit"; check "$(jq -r .exit_status "$m/manifest.json")" 137 "killed run: exit_status written by the loop"
check "$(moved kl)" "010-kl-a.json " "killed run: infra with nothing pushed stays in the queue under its own id"
rep=$(ls "$runs"/batch-*.md | tail -1); grep -q '010-kl-a | 137 |.*| nothing pushed; left in queue |' "$rep" || { echo "FAIL: killed run row"; cat "$rep"; exit 1; }
rc=$(batch "$t/lint-bad" VERIFIED); check "$rc" 1 "batch refuses bad queue"; grep -q 'fix the queue before batching' "$t/batch.out" || { echo "FAIL: refusal message"; exit 1; }
# Blocked: 010 writes docs/BLOCKED-010-bk-a.md in round 1, so the run ends before any judge round (rounds 0, verdict null), pushed, exit 10,
# outcome blocked, no PR; the note's first body line reaches the notification (its quotes escaped, so the curl config line survives) and the
# summary counts it apart. 020 then runs on main (no task has passed yet) and passes. requeue copies 010 back as 010-bk-a-r1 with the reason appended, then -r2.
queue bk 010-bk-a 020-bk-b
rc=$(STUB_WORK_BLOCKED=010-bk-a FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/bk" "VERIFIED" --continue)
check "$rc" 10 "blocked batch exit"; m=$(ls -d "$runs"/*-010-bk-a | tail -1)
check "$(jq -r '"\(.outcome) \(.reason) \(.pr_url) \(.judge.rounds) \(.judge.verdict) \(.pushed) \(.class)"' "$m/manifest.json")" 'blocked no "url" column on sandboxes null 0 null true task' "blocked manifest: outcome, reason, no PR, no judge round, pushed, task"
check "$(grep -c 'stub judge\|stub review\|stub verify' "$m/log.jsonl")" 0 "blocked: no judge, review or verifier container ran"; check "$(ls "$m" | grep -c judge-)" 0 "blocked: no judge file"; check "$(jq -c .gate "$m/manifest.json")" '{"cycles":[],"result":null}' "blocked: the gate never ran"
check "$(moved bk/failed)" "010-bk-a.json " "blocked -> failed/"; check "$(moved bk/done)" "020-bk-b.json " "blocked: the next task still ran"
check "$(sed -E 's/^batch-[0-9]+T[0-9]+Z: //' "$t/notify")" '010-bk-a exited 10 (blocked, continuing): no \"url\" column on sandboxes
done: 2 run, 0 PR(s), 0 failed, 1 blocked. All tasks ran.' "notify: reason on the phone, blocked counted apart from failed"; rm -f "$t/notify"
"$here/factory" requeue "$t/bk/failed/"*-010-bk-a.json > "$t/rq.out" || { echo "FAIL: requeue blocked"; cat "$t/rq.out"; exit 1; }
check "$(jq -r .task_id "$t/bk/010-bk-a-r1.json")" 010-bk-a-r1 "requeue id"; check "$(jq -r .repo "$t/bk/010-bk-a-r1.json")" "$t/remote.git" "requeue copies the other fields"
check "$(jq -r .instructions "$t/bk/010-bk-a-r1.json" | tail -1)" 'Previous attempt (010-bk-a) was blocked: no "url" column on sandboxes' "requeue appends the blocked reason"
mkdir -p "$t/bq/failed" "$t/bqsrc"; cp "$t/bk/failed/"*-010-bk-a.json "$t/bq/failed/"; taskd "$t/remote.git" main 010-bk-a 'Goal: old. docs/BLOCKED-<task_id>.md' "$t/bq/failed" '["000-x"]'; mv "$t/bq/failed/010-bk-a.json" "$t/bq/failed/x-010-bk-a-i1.json"
jq '.task_id="010-bk-a-i1"' "$t/bq/failed/x-010-bk-a-i1.json" > "$t/bq/failed/y.json" && mv "$t/bq/failed/y.json" "$t/bq/failed/x-010-bk-a-i1.json"
task "$t/remote.git" main 010-bk-a 'Goal: fresh spec, docs/BLOCKED-010-bk-a.md or docs/BLOCKED-<task_id>.md\nContext: c.\nScope: s.\nDone when: d.\nOut of scope: o.' "$t/bqsrc"
"$here/factory" requeue "$t/bq/failed/"*-010-bk-a.json "$t/bqsrc/010-bk-a.json" > "$t/rq.out" || { echo "FAIL: requeue with source"; cat "$t/rq.out"; exit 1; }
check "$(jq -r .instructions "$t/bq/010-bk-a-r1.json" | head -1)" 'Goal: fresh spec, docs/BLOCKED-010-bk-a-r1.md or docs/BLOCKED-010-bk-a-r1.md' "requeue takes the source's instructions, both blocked paths renamed"
check "$(jq -r .instructions "$t/bq/010-bk-a-r1.json" | tail -1)" 'Previous attempt (010-bk-a) was blocked: no "url" column on sandboxes' "requeue with source still appends the reason"
"$here/factory" requeue "$t/bq/failed/x-010-bk-a-i1.json" "$t/bqsrc/010-bk-a.json" > "$t/rq.out" || { echo "FAIL: requeue -i1 with source"; cat "$t/rq.out"; exit 1; }
check "$(jq -r '.depends_on // "none"' "$t/bq/010-bk-a-i1-r1.json")" none "requeue with source: the source's missing depends_on removes the old one"
task "$t/remote.git" main 010-bk-other 'Goal: x\nContext: c.\nScope: s.\nDone when: d.\nOut of scope: o.' "$t/bqsrc"; "$here/factory" requeue "$t/bq/failed/"*-010-bk-a.json "$t/bqsrc/010-bk-other.json" >/dev/null 2>&1 && { echo "FAIL: requeue accepted a source for another task"; exit 1; }
check "$("$here/factory" lint "$t/bk")" "lint ok: 1 task(s)" "requeued file passes lint"
# Revisions (factory.md, "Revisions"). 010 blocks; the planner (Codex) rewrites the task, the reviewer (Claude) accepts, and the batch runs
# it next as 010-rv-a-r1, without --continue, with the planner's text, the note path under the new id and the host's paragraph; 020, which
# depends on 010, then runs in the same night. The blocked attempt keeps its own record (exit 10, outcome blocked).
mkdir -p "$t/rv"; task "$t/remote.git" main 010-rv-a "$body" "$t/rv"; taskd "$t/remote.git" main 020-rv-b "$body" "$t/rv" '["010-rv-a"]'
rc=$(FACTORY_REVISE=1 STUB_WORK_BLOCKED=010-rv-a FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/rv" "VERIFIED,VERIFIED")
check "$rc" 0 "revision: the night ends green"; m=$(ls -d "$runs"/*-010-rv-a | tail -1)
check "$(moved rv/done) / $(moved rv/failed) / $(moved rv/revised)" "010-rv-a-r1.json 020-rv-b.json  / 010-rv-a.json  / 010-rv-a-r1.json 010-rv-a-r1.reason " "revision: -r1 and its dependent ran; the original is in failed/ and in revised/"
check "$(jq -r '"\(.exit_status) \(.outcome) \(.revision.disposition) \(.revision.reason)"' "$m/manifest.json")" "10 blocked proposed Done when needs x.js; Scope lists s." "revision: the blocked attempt's record stands, with the revision beside it"
check "$(jq -r .instructions "$t/rv/done/"*-010-rv-a-r1.json | sed -E 's/run [0-9TZ]+-010-rv-a/run <id>/')" 'Goal: g2.
Context: c.
Scope: s, x.js.
Done when: tests pass.
Out of scope: o. If stuck commit docs/BLOCKED-010-rv-a-r1.md.

Revised by the factory from 010-rv-a (run <id>), which ended blocked: Done when needs x.js; Scope lists s. The pull request shows the task as first written.' "revision: the planner's instructions, the note path renamed, the host's paragraph"
cmp -s "$t/rv/revised/010-rv-a-r1.json" "$t/rv/failed/"*-010-rv-a.json || { echo "FAIL: revision: revised/ does not hold the task as first written"; exit 1; }
check "$(cat "$t/rv/revised/010-rv-a-r1.reason")" 'Done when needs x.js; Scope lists s.

Scope: s -> Scope: s, x.js' "revision: the reason and the changes, for the PR"
check "$(sed -E 's/^batch-[0-9]+T[0-9]+Z: //' "$t/notify")" '010-rv-a exited 10 (blocked, revised as 010-rv-a-r1): no \"url\" column on sandboxes
done: 3 run, 0 PR(s), 0 failed, 1 blocked. All tasks ran.' "revision: the phone says it was revised"; rm -f "$t/notify"
check "$(grep -c 'stub judge secret=' "$m/log.jsonl") $(grep -c 'stub revision review' "$m/log.jsonl")" "1 1" "revision: one planner session and one review, in the blocked run"
# No revision, and the manifest says why: the planner says the wording is not the cause; the reviewer refuses the rewrite; the rewrite adds
# CI to Scope (refused by the host before any review); the planner crashes; the planner answers nonsense. The task stays blocked, nothing is queued.
norev() {  # norev <name> <disposition: reason> <what>, after a blocked batch of 010-<name>-a
  m=$(ls -d "$runs"/*-"010-$1-a" | tail -1)
  check "$rc / $(moved "$1") / $(jq -r '.revision | .disposition + ": " + .reason' "$m/manifest.json")" "10 / failed  / $2" "no revision: $3"
}
for c in rn ro rc rl rg rx ry re rh rj rb1 rb2 rb3 rb4 rb5 rb6; do mkdir -p "$t/$c"; task "$t/remote.git" main "010-$c-a" "$body" "$t/$c"; done
rc=$(FACTORY_REVISE=1 STUB_REVISE=other STUB_WORK_BLOCKED=010-rn-a batch "$t/rn" VERIFIED --continue); norev rn "none: not the task's wording: the agent could have added the column inside Scope." "the planner blames the agent"
rc=$(FACTORY_REVISE=1 STUB_REVREVIEW=block STUB_WORK_BLOCKED=010-ro-a batch "$t/ro" VERIFIED --continue); norev ro "refused: the reviewer refused it: the rewrite drops the test for y" "the reviewer refuses"
rc=$(FACTORY_REVISE=1 STUB_REVISE=ci STUB_WORK_BLOCKED=010-rc-a batch "$t/rc" VERIFIED --continue); norev rc "refused: the rewrite adds .github/workflows/ci.yml to Scope" "a workflow added to Scope"
check "$(grep -c 'stub revision review' "$m/log.jsonl")" 0 "no revision: a refused Scope never reaches the reviewer"
rc=$(FACTORY_REVISE=1 STUB_REVISE=lock STUB_WORK_BLOCKED=010-rl-a batch "$t/rl" VERIFIED --continue); norev rl "refused: the rewrite adds package-lock.json to Scope" "a lockfile added to Scope, in Markdown brackets"
rc=$(FACTORY_REVISE=1 STUB_REVISE=glob STUB_WORK_BLOCKED=010-rg-a batch "$t/rg" VERIFIED --continue); norev rg "refused: the rewrite adds **/* to Scope" "a repository-wide glob added to Scope"
rc=$(FACTORY_REVISE=1 STUB_REVISE='scope:s, .githu[bB]/workflo[wW]s/x.yml' STUB_WORK_BLOCKED=010-rb1-a batch "$t/rb1" VERIFIED --continue); norev rb1 "refused: the rewrite adds .githu[bB]/workflo[wW]s/x.yml to Scope" "a character class is not a route segment"
rc=$(FACTORY_REVISE=1 STUB_REVISE='scope:s, bun.lockb' STUB_WORK_BLOCKED=010-rb2-a batch "$t/rb2" VERIFIED --continue); norev rb2 "refused: the rewrite adds bun.lockb to Scope" "another lockfile"
rc=$(FACTORY_REVISE=1 STUB_REVISE='scope:s, the entire project' STUB_WORK_BLOCKED=010-rb3-a batch "$t/rb3" VERIFIED --continue); norev rb3 "refused: the rewrite adds a catch-all (entire project) to Scope" "a catch-all in prose"
rc=$(FACTORY_REVISE=1 STUB_REVISE='scope:s, .githu?/workflows/ci.yml' STUB_WORK_BLOCKED=010-rb5-a batch "$t/rb5" VERIFIED --continue); norev rb5 "refused: the rewrite adds .githu?/workflows/ci.yml to Scope" "a single-character glob"
rc=$(FACTORY_REVISE=1 STUB_REVISE='scope:s, Jenkinsfile' STUB_WORK_BLOCKED=010-rb6-a batch "$t/rb6" VERIFIED --continue); norev rb6 "refused: the rewrite adds Jenkinsfile to Scope" "CI configuration that is not GitHub's"
# What a real fix adds is not refused: a test file that is about setup, a workflow module of the app, a Next.js route segment.
rc=$(FACTORY_REVISE=1 STUB_REVISE='scope:s, apps/web/test/setup.test.ts, src/workflow/render.ts, apps/web/app/api/sandboxes/[id]/fs/[op]/route.ts, apps/web/app/[id], apps/web/app/[[...slug]]' STUB_WORK_BLOCKED=010-rb4-a batch "$t/rb4" VERIFIED --continue)
check "$rc $(moved rb4/done)" "0 010-rb4-a-r1.json " "revision: ordinary test, module and route paths are accepted"
rc=$(FACTORY_REVISE=1 STUB_REVISE=crash STUB_WORK_BLOCKED=010-rx-a batch "$t/rx" VERIFIED --continue); norev rx "error: the planner left no valid answer (container status 1)" "the planner crashed"
rc=$(FACTORY_REVISE=1 STUB_REVISE=bad STUB_WORK_BLOCKED=010-ry-a batch "$t/ry" VERIFIED --continue); norev ry "error: the planner left no valid answer (container status 0)" "the planner's answer is not JSON"
rc=$(FACTORY_REVISE=1 STUB_REVREVIEW=crash STUB_WORK_BLOCKED=010-rh-a batch "$t/rh" VERIFIED --continue); norev rh "refused: the revision review left no valid answer (container status 1)" "the reviewer crashed: no answer is not a pass"
# A rewrite the reviewer accepted but lint refuses is not queued, leaves nothing in revised/, and is recorded as refused.
rc=$(FACTORY_REVISE=1 STUB_REVISE=nolint STUB_WORK_BLOCKED=010-rj-a batch "$t/rj" VERIFIED --continue); m=$(ls -d "$runs"/*-010-rj-a | tail -1)
check "$rc / $(moved rj) / $(ls "$t/rj/revised" | wc -l | tr -d ' ') / $(jq -r '.revision | .disposition + ": " + .reason' "$m/manifest.json" | cut -c1-87)" "10 / failed revised  / 0 / refused: the revised task fails lint: 010-rj-a-r1: instructions need the headings Goal," "no revision: the rewrite fails lint"
# The planner's log pipeline fails (run_container writes outcome evidence_error into the manifest and exits 12, in the subshell): the
# blocked attempt's record is put back as it was, and only .revision says the step did not finish.
rc=$(FACTORY_REVISE=1 STUB_JQ_FAIL=judge STUB_WORK_BLOCKED=010-re-a batch "$t/re" VERIFIED --continue); m=$(ls -d "$runs"/*-010-re-a | tail -1)
check "$rc $(jq -r '"\(.exit_status) \(.outcome) \(.class) \(.revision.disposition)"' "$m/manifest.json")" "10 10 blocked task error" "revision: a lost log in the planner step leaves the blocked record as it was"
# The revision is taken by name and leaves the cursor: an id that sorts between the task and its -r1 still runs.
mkdir -p "$t/rk"; for i in 010-rk-a 010-rk-a-foo 020-rk-b; do task "$t/remote.git" main "$i" "$body" "$t/rk"; done
rc=$(FACTORY_REVISE=1 STUB_WORK_BLOCKED=010-rk-a batch "$t/rk" "VERIFIED,VERIFIED,VERIFIED"); check "$rc $(moved rk/done)" "0 010-rk-a-r1.json 010-rk-a-foo.json 020-rk-b.json " "revision: a task between <id> and <id>-r1 is not skipped (done/ lists in run order)"
# A revision whose run fails with nothing pushed stays in the queue for tomorrow and is not taken a second time tonight (the cursor
# is still behind it): one run of 010-ru-a-r1, the file still queued.
mkdir -p "$t/ru"; task "$t/remote.git" main 010-ru-a "$body" "$t/ru"
rc=$(FACTORY_REVISE=1 STUB_PUSH_FAIL_AT=2 STUB_WORK_BLOCKED=010-ru-a batch "$t/ru" "VERIFIED,VERIFIED,VERIFIED" --continue)
check "$(ls -d "$runs"/*-010-ru-a-r1 | wc -l | tr -d ' ') $(ls "$t/ru" | tr '\n' ' ')" "1 010-ru-a-r1.json failed revised " "revision: a revision left in the queue by an infra failure is not run twice in one night"
# An id already used is never reused: the proposal is recorded as refused and the task stays blocked.
mkdir -p "$t/rz/done"; task "$t/remote.git" main 010-rz-a "$body" "$t/rz"; echo '{}' > "$t/rz/done/20261101T000000Z-010-rz-a-r1.json"
rc=$(FACTORY_REVISE=1 STUB_WORK_BLOCKED=010-rz-a batch "$t/rz" VERIFIED); m=$(ls -d "$runs"/*-010-rz-a | tail -1)
check "$rc $(jq -r '.revision | .disposition + ": " + .reason' "$m/manifest.json") $(ls "$t/rz" | tr '\n' ' ')" "10 refused: 010-rz-a-r1 exists done failed " "revision: an id that exists is not reused"
# Once per task, and never under the merge gate: a blocked -r1 gets no planner, and with a merger App set nothing is revised.
mkdir -p "$t/rw"; task "$t/remote.git" main 010-rw-a-r1 "$body" "$t/rw"
rc=$(FACTORY_REVISE=1 STUB_WORK_BLOCKED=010-rw-a-r1 batch "$t/rw" VERIFIED --continue); m=$(ls -d "$runs"/*-010-rw-a-r1 | tail -1)
check "$rc $(jq -r '.revision // "none"' "$m/manifest.json") $(grep -c 'stub judge secret=' "$m/log.jsonl")" "10 none 0" "revision: a task that was revised once is not revised again"
mkdir -p "$t/rmg"; task "$t/remote.git" main 010-rmg-a "$body" "$t/rmg"
rc=$(FACTORY_MERGER_APP_ID=Iv1.merger FACTORY_REVISE=1 STUB_WORK_BLOCKED=010-rmg-a batch "$t/rmg" VERIFIED --continue); m=$(ls -d "$runs"/*-010-rmg-a | tail -1)
check "$rc $(jq -r '.revision // "none"' "$m/manifest.json") $(grep -c 'stub judge secret=' "$m/log.jsonl")" "10 none 0" "revision: off under the merge gate"
rc=$(FACTORY_REVISE=1 STUB_WORK_BLOCKED=rvp run rvp VERIFIED); m=$(ls -d "$runs"/*-rvp | tail -1)
check "$rc $(jq -r '.revision // "none"' "$m/manifest.json") $(grep -c 'stub judge secret=' "$m/log.jsonl")" "10 none 0" "revision: a run outside a batch asks no planner (nothing would queue the answer)"
# Deep lint: a contradiction that comes with a rewrite is revised in place, under the same id, once the reviewer accepts it; the task as
# it was goes to revised/. The second night finds revised/<id>.json and holds instead; a rewrite the reviewer refuses is a hold as before.
dra() { answer '{tasks:[{task_id:"010-'"$1"'-a",depends_on:[],hold:{kind:"'"${2:-contradiction}"'",reason:"Done when needs x.js; Scope lists s.",proposed_instructions:"Goal: g.\nContext: c.\nScope: s, x.js.\nDone when: tests pass.\nOut of scope: o."}},{task_id:"020-'"$1"'-b",depends_on:[],hold:null}]}' "$1"; }
queue dr 010-dr-a 020-dr-b; cp "$t/dr/010-dr-a.json" "$t/dr-010.orig"; a=$(dra dr)
rc=$(FACTORY_REVISE=1 deep "$t/dr" "$a"); check "$rc" 0 "deep lint revision: applied"
check "$(moved dr) / $(moved dr/revised) / $(moved dr/held)" "010-dr-a.json 020-dr-b.json held revised  / 010-dr-a.json 010-dr-a.reason  / " "deep lint revision: the task stays queued under its id; nothing is held"
check "$(jq -r .instructions "$t/dr/010-dr-a.json" | sed -E 's/run [0-9TZ]+-deep-lint/run <id>/')" 'Goal: g.
Context: c.
Scope: s, x.js.
Done when: tests pass.
Out of scope: o.

Revised by deep lint (run <id>), contradiction: Done when needs x.js; Scope lists s. The pull request shows the task as first written.' "deep lint revision: the rewrite, then the host's paragraph"
cmp -s "$t/dr/revised/010-dr-a.json" "$t/dr-010.orig" || { echo "FAIL: deep lint revision: revised/ does not hold the task as it was"; exit 1; }
check "$(cat "$t/dr/revised/010-dr-a.reason") $(dlm '[.deep_lint.result, (.deep_lint.revised|length), (.deep_lint.held|length)] | @json')" 'contradiction: Done when needs x.js; Scope lists s. ["applied",1,0]' "deep lint revision: the reason and the manifest"
grep -q '^deep lint: 0 task(s) gained depends_on, 0 held, 1 revised$' "$t/deep.out" || { echo "FAIL: deep lint revision not said"; cat "$t/deep.out"; exit 1; }
check "$("$here/factory" lint "$t/dr" | tail -1)" "lint ok: 2 task(s)" "deep lint revision: the result passes lint"
rc=$(FACTORY_REVISE=1 deep "$t/dr" "$a"); check "$rc $(moved dr/held) $(dlm '.deep_lint.held[0].rewrite_not_used')" "0 010-dr-a.json 010-dr-a.proposed.json 010-dr-a.reason  revised once already" "deep lint revision: once per task; the second objection is a hold"
queue ds 010-ds-a 020-ds-b; a=$(dra ds); rc=$(FACTORY_REVISE=1 STUB_REVREVIEW=block deep "$t/ds" "$a")
check "$rc $(moved ds/held) $(ls "$t/ds/revised" 2>/dev/null | wc -l | tr -d ' ')" "0 010-ds-a.json 010-ds-a.proposed.json 010-ds-a.reason  0" "deep lint revision: a rewrite the reviewer refuses is held as before"
check "$(dlm '.deep_lint.held[0].rewrite_not_used')" "the reviewer refused it: the rewrite drops the test for y" "deep lint revision: the manifest says why the rewrite was not used"
# An ambiguity with a rewrite is revised the same way. A rewrite that also relies on a later task is a hold, as it was before revisions
# (the staged queue would fail lint and nothing would be applied). And one deep lint sends at most three rewrites to the reviewer.
queue dw 010-dw-a 020-dw-b; a=$(dra dw ambiguity); rc=$(FACTORY_REVISE=1 deep "$t/dw" "$a")
check "$rc $(cat "$t/dw/revised/010-dw-a.reason")" "0 ambiguity: Done when needs x.js; Scope lists s." "deep lint revision: an ambiguity"
queue dv 010-dv-a 020-dv-b; a=$(answer '{tasks:[{task_id:"010-dv-a",depends_on:["020-dv-b"],hold:{kind:"contradiction",reason:"r.",proposed_instructions:"Goal: g.\nContext: c.\nScope: s, x.js.\nDone when: tests pass.\nOut of scope: o."}},{task_id:"020-dv-b",depends_on:[],hold:null}]}' dv)
rc=$(FACTORY_REVISE=1 deep "$t/dv" "$a"); check "$rc $(moved dv/held) $(dlm '.deep_lint.held[0].rewrite_not_used')" "0 010-dv-a.json 010-dv-a.proposed.json 010-dv-a.reason  it also relies on 020-dv-b, which cannot be waited for" "deep lint revision: a rewrite with a later supplier is held, and the rest of the answer is still applied"
queue dcap 010-dcap-a 020-dcap-b 030-dcap-c 040-dcap-d; a=$(answer '{tasks:[("010-dcap-a","020-dcap-b","030-dcap-c","040-dcap-d") | {task_id:., depends_on:[], hold:{kind:"contradiction",reason:"r.",proposed_instructions:"Goal: g.\nContext: c.\nScope: s, x.js.\nDone when: tests pass.\nOut of scope: o."}}]}' dcap)
rc=$(FACTORY_REVISE=1 deep "$t/dcap" "$a"); check "$rc $(dlm '[(.deep_lint.revised|length), (.deep_lint.held|map(.task_id + ": " + .rewrite_not_used)|join(","))] | @json')" '0 [3,"040-dcap-d: more than 3 rewrites in one deep lint"]' "deep lint revision: at most three reviews; the fourth rewrite is held"
# A task deep lint revised in place and that then blocks gets no planner: it was revised once.
queue du 010-du-a 020-du-b; a=$(dra du)
sleep 1; rc=$(FACTORY_DEEP_LINT=1 FACTORY_REVISE=1 STUB_DEEP="$a" STUB_WORK_BLOCKED=010-du-a batch "$t/du" VERIFIED --continue); m=$(ls -d "$runs"/*-010-du-a | tail -1)
check "$rc $(jq -r '.revision // "none"' "$m/manifest.json") $(grep -c 'stub judge secret=' "$m/log.jsonl")" "10 none 0" "revision: a task deep lint revised is not revised again after a block"
# Inside a batch: the revision is notified with its reason, has its row, and the task runs the same night.
queue dn 010-dn-a 020-dn-b; a=$(dra dn)
sleep 1; rc=$(FACTORY_DEEP_LINT=1 FACTORY_REVISE=1 STUB_DEEP="$a" FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/dn" "VERIFIED,VERIFIED"); check "$rc $(moved dn/done)" "0 010-dn-a.json 020-dn-b.json " "deep lint revision in a batch: the task ran"
check "$(head -1 "$t/notify" | sed -E 's/^batch-[0-9]+T[0-9]+Z: //')" "010-dn-a revised by deep lint (contradiction): Done when needs x.js; Scope lists s.; it runs as revised, and its PR shows the task as written" "deep lint revision in a batch: notified"; rm -f "$t/notify"
rep=$(ls "$runs"/batch-*.md | tail -1); grep -q '^| - | revised | - | - | - | - | - | 010-dn-a (contradiction): Done when needs x.js; Scope lists s. |$' "$rep" && grep -q 'deep lint: run [0-9TZ]*-deep-lint, 0 task(s) gained depends_on, 0 held, 1 revised$' "$rep" || { echo "FAIL: deep lint revision not in the report"; cat "$rep"; exit 1; }
"$here/factory" requeue "$t/bk/failed/"*-010-bk-a.json > /dev/null; check "$(ls "$t/bk"/*.json | xargs -n1 basename | tr '\n' ' ')" "010-bk-a-r1.json 010-bk-a-r2.json " "requeue numbers past the queued retry"
# requeue a refuted run: the last judge file is appended; a skipped task (no run) gets nothing appended.
"$here/factory" requeue "$t/rf/failed/"*-020-rf-b.json > /dev/null; i=$(jq -r .instructions "$t/rf/020-rf-b-r1.json")
case "$i" in *"Previous attempt (020-rf-b): judge REFUTED after 3 round(s). Findings:"$'\n'"finding 4: fix it"*) ;; *) echo "FAIL: requeue refuted findings: $i"; exit 1;; esac   # the stub judge numbers findings per batch: 010 took 1
"$here/factory" requeue "$t/sw/failed/"*-030-sw-c.json > /dev/null; check "$(jq -r .instructions "$t/sw/030-sw-c-r1.json")" "$(printf "$body")" "requeue of a skipped task appends nothing"
find "$runs" -maxdepth 1 -newer "$t/secrets" \( -name 'batch-*.md' -o -name '*-0[0-9][0-9]-[a-z][a-z]-[a-z]' -o -name '*-0[0-9][0-9]-[a-z][a-z]-[a-z]-i1' \) -exec rm -rf {} +   # only what this test made
rc=$(STUB_WORK_IDLE_ROUND=2 run t6 "CAVEATS"); m=$(ls -d "$runs"/*-t6 | tail -1)
check "$rc" 0 "t6 exit (caveats, idle revision ships)"; check "$(jq -r .judge.rounds "$m/manifest.json")" 1 "t6 rounds counts judged rounds only"
# The note at the pushed head decides blocked, not "the only change": a note on top of code is blocked (no judge, exit 10, never a PR); a note
# written in round 2 after a REFUTED round 1 ends the run with round 1's record; a note committed then deleted is not at head and ships; a note
# beside a manifest change is the manifest refusal (exit 14), which sits ahead of blocked.
rc=$(STUB_WORK_BLOCKED=t15 STUB_NOTE=code run t15 VERIFIED); m=$(ls -d "$runs"/*-t15 | tail -1)
check "$rc" 10 "t15 exit (note on top of code is blocked)"; check "$(jq -r '"\(.outcome) \(.judge.rounds) \(.judge.verdict) \(.pr_url)"' "$m/manifest.json")" "blocked 0 null null" "t15 no judge round, no PR"; check "$(grep -c 'stub judge' "$m/log.jsonl")" 0 "t15 no judge container"
rc=$(STUB_WORK_BLOCKED=t16 STUB_NOTE=round2 run t16 REFUTED); m=$(ls -d "$runs"/*-t16 | tail -1)
check "$rc" 10 "t16 exit (note in round 2)"; check "$(jq -r '"\(.outcome) \(.judge.rounds) \(.judge.verdict) \(.class)"' "$m/manifest.json")" "blocked 1 REFUTED task" "t16 round 1's record kept, blocked wins over refuted"; check "$(ls "$m" | grep -c judge-)" 1 "t16 one judge file"
rc=$(STUB_WORK_BLOCKED=t17 STUB_NOTE=deleted run t17 VERIFIED); m=$(ls -d "$runs"/*-t17 | tail -1)
check "$rc" 0 "t17 exit (a deleted note is not at head)"; check "$(jq -r '"\(.outcome // "none") \(.judge.rounds)"' "$m/manifest.json")" "none 1" "t17 judged and shipped"
rc=$(STUB_WORK_BLOCKED=t18 STUB_NOTE=dep run t18 VERIFIED); m=$(ls -d "$runs"/*-t18 | tail -1)
check "$rc" 14 "t18 exit (manifest gate ahead of blocked)"; check "$(jq -r .outcome "$m/manifest.json")" dependency_change "t18 outcome"
rc=$(STUB_WORK_BLOCKED=t19 STUB_NOTE=dir run t19 VERIFIED); m=$(ls -d "$runs"/*-t19 | tail -1)
check "$rc" 0 "t19 exit (a directory at the note's path is not a note: judged, shipped)"; check "$(jq -r '"\(.outcome // "none") \(.judge.rounds) \(.judge.verdict)"' "$m/manifest.json")" "none 1 VERIFIED" "t19 judged normally"
# The loop's note check reads the worker's checkout, which can carry a refs/replace entry that makes the real head read as a note commit. The
# check ignores replacements (--no-replace-objects), so the judge still runs on the real head and the verdict is about the head that is pushed.
rc=$(STUB_WORK_BLOCKED=t20 STUB_NOTE=replace run t20 "CAVEATS,VERIFIED"); m=$(ls -d "$runs"/*-t20 | tail -1)
check "$rc" 0 "t20 exit (a replace ref does not skip the judge)"; check "$(jq -r '"\(.outcome // "none") \(.judge.rounds) \(.judge.verdict)"' "$m/manifest.json")" "none 2 VERIFIED" "t20 round 2 was judged"; check "$(grep -c 'stub judge' "$m/log.jsonl")" 2 "t20 two judge rounds ran"
rc=$(STUB_WORK_BLOCKED=t21 STUB_NOTE=round2 run t21 CAVEATS); m=$(ls -d "$runs"/*-t21 | tail -1)
check "$rc" 10 "t21 exit (note in round 2 after CAVEATS does not ship)"; check "$(jq -r '"\(.outcome) \(.judge.rounds) \(.judge.verdict) \(.pr_url)"' "$m/manifest.json")" "blocked 1 CAVEATS null" "t21 blocked wins over caveats"
check "$(cat "$t/prompt")" 'task_id: t21 (a blocked note is docs/BLOCKED-t21.md)' "t21 worker prompt names the task_id and note path"
# The verification gate (loop 0), after the push and the cheap gates: a fresh break-it review (its prompt never carries the loop judge's
# findings), then the verifier runs each BLOCK's repro at head and base (the real verify.js, against the host mounts). Nothing reproduced:
# the PR, with the cycle in the manifest and the evidence files. A BLOCK failing at both with no clause is pre-existing; a repro that passes,
# times out or is not found is invalid; more than MAX_BLOCKS is truncated. None of these block.
g() { jq -r "$1" "$m/manifest.json"; }
rc=$(run g1 VERIFIED); m=$(ls -d "$runs"/*-g1 | tail -1)
check "$rc" 0 "g1 exit (clean gate ships)"; check "$(g '"\(.gate.result) \(.gate.cycles|length) \(.gate.cycles[0].reproduced) \(.gate.cycles[0].reviews[0].lens) \(.gate.cycles[0].reviews[0].valid) \(.gate.cycles[0].verifier.valid) \(.gate.cycles[0].reviews[0].notes[0])"')" "pass 1 0 break-it true true looks fine" "g1 gate record"
check "$(ls "$m" | grep -c '^gate-0-')" 2 "g1 evidence: gate-0-breakit.json and gate-0-verify.json"; check "$(jq -c '.install' "$m/gate-0-verify.json")" '{"head":null,"base":null}' "g1 nothing to install in the stub repo"
rc=$(FACTORY_GATE=0 STUB_REVIEW=crash run g0 VERIFIED); m=$(ls -d "$runs"/*-g0 | tail -1); check "$rc" 0 "g0 exit (FACTORY_GATE=0 skips the gate)"; check "$(g '"\(.gate.result) \(.gate.cycles|length)"')" "skipped 0" "g0 the manifest says the gate was skipped"; check "$(grep -c 'stub review' "$m/log.jsonl")" 0 "g0 no review container"
rc=$(STUB_REVIEW=preexist run g2 VERIFIED); m=$(ls -d "$runs"/*-g2 | tail -1)
check "$rc" 0 "g2 exit (pre-existing failure is a note)"; check "$(g '"\(.gate.cycles[0].verifier.blocks[0].class) \(.gate.cycles[0].verifier.blocks[0].head_exit) \(.gate.cycles[0].verifier.blocks[0].base_exit) \(.gate.cycles[0].reproduced)"')" "pre-existing 1 1 0" "g2 classified pre-existing"
rc=$(STUB_REVIEW=invalid run g3 VERIFIED); m=$(ls -d "$runs"/*-g3 | tail -1)
check "$rc" 0 "g3 exit (invalid repros never block)"; check "$(g '[.gate.cycles[0].verifier.blocks[] | "\(.class):\(.head_exit)/\(.base_exit)"] | join(" ")')" "invalid:0/0 invalid:124/124 invalid:127/127 invalid:1/127 pre-existing:1/1" "g3 passes, a real timeout, not found, a base that cannot run: all invalid; a repro that writes the tree does not change the next one's answer"
rc=$(STUB_REVIEW=many run g4 VERIFIED); m=$(ls -d "$runs"/*-g4 | tail -1)
check "$rc" 0 "g4 exit"; check "$(g '"\(.gate.cycles[0].reviews[0].blocks) \(.gate.cycles[0].reviews[0].truncated) \(.gate.cycles[0].verifier.blocks|length)"')" "10 true 10" "g4 blocks truncated to MAX_BLOCKS"
# A reproduced regression (fails at head, passes at base) costs one worker round with the facts, one judge round with the facts, and a
# re-gate; judge.rounds counts the cycle's round; the second gate passes and the PR opens. An unmet clause (fails at both, clause named)
# reproduces too.
rc=$(STUB_REVIEW=regress,none STUB_FIXES="$t/fixes" run g5 "VERIFIED,VERIFIED"); m=$(ls -d "$runs"/*-g5 | tail -1)
check "$rc" 0 "g5 exit (regression fixed in one cycle ships)"; check "$(g '"\(.gate.result) \(.gate.cycles|length) \(.gate.cycles[0].reproduced) \(.gate.cycles[0].verifier.blocks[0].class) \(.gate.cycles[1].reproduced) \(.judge.rounds) \(.judge.verdict) \(.worker.rounds|length) \(.outcome // "none")"')" "pass 2 1 regression 0 2 VERIFIED 2 none" "g5 two cycles, two judged rounds"
check "$(cat "$t/fixes")" '- a.js:1: work.log must not exist [regression; exit 1 at head, 0 at base; repro: ! test -e work.log]' "g5 the worker got the reproduced finding as a fact"; rm -f "$t/fixes"
check "$(grep -c 'stub judge: saw gate facts' "$m/log.jsonl")" 1 "g5 the cycle's judge got the gate's facts in the facts section"; check "$(ls "$m" | grep -c '^gate-1-')" 2 "g5 second cycle's evidence files"
rc=$(STUB_REVIEW=unmet,unmet run g6 "VERIFIED,VERIFIED"); m=$(ls -d "$runs"/*-g6 | tail -1)
check "$rc" 0 "g6 exit (unmet clause, then fixed)"; check "$(g '"\(.gate.cycles[0].verifier.blocks[0].class) \(.gate.cycles[0].reproduced) \(.gate.cycles|length) \(.gate.cycles[1].verifier.blocks[0].head_exit) \(.gate.cycles[1].verifier.blocks[0].class) \(.gate.cycles[1].reproduced)"')" "unmet 1 2 0 invalid 0" "g6 unmet reproduces; the same repro passes after the fix and is not a repeat"
# Missing verification is never approval: a review that crashed, invalid findings, or a verifier that left no record is gate_pending, exit 12, infra.
rc=$(STUB_REVIEW=crash run g7 VERIFIED); m=$(ls -d "$runs"/*-g7 | tail -1)
check "$rc" 12 "g7 exit (review crashed)"; check "$(g '"\(.outcome) \(.class) \(.pushed) \(.pr_url) \(.gate.result) \(.gate.cycles[0].reviews[0].valid) \(.gate.cycles[0].reviews[0].status) \(.reason)"')" "gate_pending infra true null gate_pending false 1 the review left no valid findings (container status 1)" "g7 gate_pending with the reason, never a pass"
rc=$(STUB_REVIEW=bad run g8 VERIFIED); m=$(ls -d "$runs"/*-g8 | tail -1); check "$rc" 12 "g8 exit (invalid findings file)"; check "$(g '"\(.outcome) \(.gate.cycles[0].reviews[0].valid)"')" "gate_pending false" "g8 invalid JSON is no review"
rc=$(STUB_VERIFY_CRASH=1 run g9 VERIFIED); m=$(ls -d "$runs"/*-g9 | tail -1); check "$rc" 12 "g9 exit (verifier crashed)"; check "$(g '"\(.outcome) \(.gate.cycles[0].reviews[0].valid) \(.gate.cycles[0].verifier.valid) \(.gate.cycles[0].verifier.status)"')" "gate_pending true false 1" "g9 no verifier record is gate_pending"
# Death is on no progress: no new commits in a cycle; the same repro reproducing in a later cycle; REFUTED from the loop judge in a cycle;
# the ceiling of MAX_GATES cycles. Each: outcome refuted, refuted_by gate, exit 5, class task, no PR, branch pushed.
rc=$(STUB_REVIEW=regress STUB_FIX=idle run g10 VERIFIED); m=$(ls -d "$runs"/*-g10 | tail -1)
check "$rc" 5 "g10 exit (no new commits in a cycle)"; check "$(g '"\(.outcome) \(.refuted_by) \(.class) \(.pr_url) \(.pushed) \(.judge.rounds) \(.gate.result) \(.gate.cycles|length)"')" "refuted gate task null true 1 refuted 1" "g10 refuted by the gate"
rc=$(STUB_REVIEW=regress,regress STUB_FIX=nofix run g11 "VERIFIED,VERIFIED"); m=$(ls -d "$runs"/*-g11 | tail -1)
check "$rc" 5 "g11 exit (the same repro reproduced twice)"; check "$(g '"\(.outcome) \(.refuted_by) \(.judge.rounds) \(.gate.cycles|length) \(.gate.cycles[1].reproduced)"')" "refuted gate 2 2 1" "g11 dead after the second reproduction"
grep -q 'a finding reproduced again' "$m/log.jsonl" || { echo "FAIL: g11 reason not logged"; exit 1; }
rc=$(STUB_REVIEW=regress run g12 "VERIFIED,REFUTED"); m=$(ls -d "$runs"/*-g12 | tail -1)
check "$rc" 5 "g12 exit (REFUTED in a gate cycle is dead)"; check "$(g '"\(.outcome) \(.refuted_by) \(.judge.rounds) \(.judge.verdict) \(.gate.cycles|length)"')" "refuted gate 2 REFUTED 1" "g12 no second gate, no more rounds"; check "$(ls "$m" | grep -c judge-)" 2 "g12 two judge files"
rc=$(FACTORY_MAX_ROUNDS=1 STUB_FIX=nofix STUB_REVIEW=regress,unmet1,unmet2,unmet3 run g13 "VERIFIED,VERIFIED,VERIFIED,VERIFIED"); m=$(ls -d "$runs"/*-g13 | tail -1)
check "$rc" 5 "g13 exit (MAX_GATES ceiling; cycles run past MAX_ROUNDS)"; check "$(g '"\(.outcome) \(.refuted_by) \(.judge.rounds) \(.gate.cycles|length) \([.gate.cycles[].reproduced]|add)"')" "refuted gate 4 4 4" "g13 four cycles, four judged rounds"
grep -q 'the gate ceiling (4) is reached' "$m/log.jsonl" || { echo "FAIL: g13 reason not logged"; exit 1; }
# Pushed means pushed, across cycles: a push that fails in cycle 2 leaves the first cycle's commit recorded as what is on GitHub (pushed true,
# final_sha the remote branch), outcome push_failed; a first push that fails records nothing on GitHub. A stop landing while the review runs
# keeps the review's record and the push facts: gate_pending, halted, pushed.
rc=$(STUB_REVIEW=regress STUB_PUSH_FAIL_AT=2 run g15 "VERIFIED,VERIFIED"); m=$(ls -d "$runs"/*-g15 | tail -1)
check "$rc" 8 "g15 exit (the second push failed)"; check "$(g '"\(.outcome) \(.pushed) \(.push_status) \(.class) \(.pr_url) \(.gate.cycles|length)"')" "push_failed true 8 infra null 1" "g15 the first push stands"
check "$(g .final_sha)" "$(git -C "$t/remote.git" rev-parse refs/heads/factory/g15)" "g15 final_sha is the commit on GitHub (cycle 1's), not the unpushed fix"
rc=$(STUB_PUSH_FAIL_AT=1 run g16 VERIFIED); m=$(ls -d "$runs"/*-g16 | tail -1)
check "$rc" 8 "g16 exit (first push failed)"; check "$(g '"\(.outcome) \(.pushed) \(.final_sha) \(.push_status) \(.class)"')" "push_failed false null 8 infra" "g16 nothing on GitHub"
rc=$(STUB_HALT_IN_REVIEW=1 STUB_HALT_FILE="$here/HALT" run g17 VERIFIED); m=$(ls -d "$runs"/*-g17 | tail -1); rm -f "$here/HALT"
check "$rc" 12 "g17 exit (stopped during the review)"; check "$(g '"\(.outcome) \(.class) \(.pushed) \(.gate.cycles[0].halted) \(.gate.cycles[0].reviews[0].valid) \(.gate.cycles[0].verifier) \(.reason)"')" "gate_pending infra true true true null stopped before the gate's verify step" "g17 the review's record and the push are kept; the verifier never ran"
check "$(g .final_sha)" "$(git -C "$t/remote.git" rev-parse refs/heads/factory/g17)" "g17 final_sha persisted before the stop"
# The differential test checks, on a repo with a package.json and a lockfile (npm ci installs nothing): the worker changes a test and the
# file it reads, so the base's test fails at head (a test changed under the code: a note) and the head's test fails at base (it tests the change).
git init -q --bare "$t/diff.git"; git clone -q "$t/remote.git" "$t/diff" 2>/dev/null
( cd "$t/diff" && echo old > a.txt && printf 'if (require("fs").readFileSync("a.txt","utf8").trim() !== "new") process.exit(1)\n' | sed 's/"new"/"old"/' > t.test.js \
  && echo '{"name":"x","version":"1.0.0","scripts":{"test":"node t.test.js"}}' > package.json && echo '{"name":"x","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"x","version":"1.0.0"}}}' > package-lock.json \
  && git add . && git -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -qm diff && git push -q "$t/diff.git" HEAD:main )
rc=$(RUN_REPO="$t/diff.git" STUB_WORK_DIFF=1 run g14 VERIFIED); m=$(ls -d "$runs"/*-g14 | tail -1)
check "$rc" 0 "g14 exit (differential checks are notes)";
check "$(g '.gate.cycles[0].verifier | "\(.install.head) \(.install.base) \(.checks.test_files|join(",")) \(.checks.base_tests_at_head) \(.checks.head_tests_at_base)"')" "0 0 t.test.js 1 1" "g14 npm ci ran at both, base tests fail at head, head tests fail at base"
( cd "$t/diff" && git rm -q package-lock.json && git -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -qm nolock && git push -q "$t/diff.git" HEAD:main )
rc=$(RUN_REPO="$t/diff.git" run g18 VERIFIED); m=$(ls -d "$runs"/*-g18 | tail -1); check "$rc" 12 "g18 exit (no lockfile: npm ci fails)"; check "$(g '"\(.outcome) \(.gate.cycles[0].verifier.install.head) \(.reason)"')" 'gate_pending 1 npm ci failed in the verifier: {"head":1,"base":null} (a package.json with no lockfile fails it)' "g18 a failed install is gate_pending with the reason, never a pass"
# Verdict parsing fails closed: CRLF is normalised (else VERIFIED\r equals no verdict); two VERDICT lines, or a review the bounded
# read cut (its first 200000 bytes end in a clean VERDICT line), are no verdict. A worker that fails in round 1 has zero judged rounds.
rc=$(run t7 CRLF); m=$(ls -d "$runs"/*-t7 | tail -1); check "$rc" 0 "t7 exit (CRLF verdict)"; check "$(jq -r '"\(.judge.verdict) \(.judge.rounds)"' "$m/manifest.json")" "VERIFIED 1" "t7 verdict without \\r"
rc=$(run t8 DOUBLE); m=$(ls -d "$runs"/*-t8 | tail -1); check "$rc" 6 "t8 exit (two VERDICT lines is no verdict)"
rc=$(run t9 BIG); m=$(ls -d "$runs"/*-t9 | tail -1); check "$rc" 6 "t9 exit (review over 200000 bytes is no verdict)"; grep -q 'over 200000 bytes' "$m/log.jsonl" || { echo "FAIL: t9 oversize not logged"; exit 1; }
rc=$(STUB_WORK_FAIL_ROUND=1 run t10 VERIFIED); m=$(ls -d "$runs"/*-t10 | tail -1); check "$rc" 7 "t10 exit"; check "$(jq -r '"\(.judge.rounds) \(.judge.verdict) \(.final_sha) \(.pushed) \(.class)"' "$m/manifest.json")" "0 null null false infra" "t10 no judge round, nothing pushed, infra"
# Conflict gate: main moves under the run (the judge stub pushes a conflicting README.md), so a VERIFIED branch gets no PR: exit 11.
rc=$(STUB_CONFLICT="$t/remote.git" run t12 VERIFIED); m=$(ls -d "$runs"/*-t12 | tail -1)
check "$rc" 11 "t12 exit (conflicts with the target)"; check "$(jq -r '"\(.outcome) \(.judge.verdict) \(.pr_url) \(.class)"' "$m/manifest.json")" "conflict VERIFIED null infra" "t12 outcome conflict, verdict kept, no PR, infra"
grep -q 'conflicts with main; no PR' "$m/log.jsonl" || { echo "FAIL: t12 conflict not logged"; exit 1; }; check "$(grep -c 'stub review' "$m/log.jsonl")" 0 "t12 a conflict never reaches the verification gate"
( cd "$t/seed" && git pull -q origin main && echo hi > README.md && git -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -qam reset && git push -q origin HEAD:main )   # put main back
# A base fetch that fails is a gate error (exit 12), never reported as a conflict.
rc=$(STUB_DROP_BASE="$t/remote.git" run t14 VERIFIED); m=$(ls -d "$runs"/*-t14 | tail -1)
check "$rc" 12 "t14 exit (base fetch failed)"; check "$(jq -r '"\(.outcome) \(.pr_url)"' "$m/manifest.json")" "gate_error null" "t14 outcome gate_error, no PR"
( cd "$t/seed" && git push -q origin HEAD:main )   # put main back
# requeue numbering reads task_id literally: 010-x.y-r2 (zero-padded r08 also counted as 8) -> next is -r9; 020-010-x.y-r5 is another task.
mkdir -p "$t/rq/failed"; task o/r main 010-x.y 'Goal: g. If stuck commit docs/BLOCKED-010-x.y.md (not docs/BLOCKED-010-xzy.md).\nDone when: y.' "$t/rq/failed"; task o/r main 010-x.y-r08 "$body" "$t/rq"; task o/r main 020-010-x.y-r5 "$body" "$t/rq"
"$here/factory" requeue "$t/rq/failed/010-x.y.json" > /dev/null; check "$(ls "$t/rq"/*.json | xargs -n1 basename | tr '\n' ' ')" "010-x.y-r08.json 010-x.y-r9.json 020-010-x.y-r5.json " "requeue numbering"
check "$(jq -r .instructions "$t/rq/010-x.y-r9.json")" 'Goal: g. If stuck commit docs/BLOCKED-010-x.y-r9.md (not docs/BLOCKED-010-xzy.md).
Done when: y.' "requeue rewrites the note path in the task text to the new id (literally: the dot is not a wildcard)"
# The default round limit is five: four refusals then VERIFIED ships with rounds 5.
rc=$(FACTORY_MAX_ROUNDS=5 run t13 "REFUTED,REFUTED,REFUTED,REFUTED,VERIFIED"); m=$(ls -d "$runs"/*-t13 | tail -1)
check "$rc" 0 "t13 exit (five rounds)"; check "$(jq -r '"\(.judge.rounds) \(.judge.verdict)"' "$m/manifest.json")" "5 VERIFIED" "t13 rounds"
check "$(grep -o 'MAX_ROUNDS="${FACTORY_MAX_ROUNDS:-5}"' "$here/factory" | wc -l | tr -d ' ')" 1 "default round limit is 5"
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
rc=$(RUN_REPO=o/r STUB_PRS="$t/prs-g" STUB_REVIEW=preexist run gh7 VERIFIED); m=$(ls -d "$runs"/*-gh7 | tail -1); check "$rc" 0 "gh7 exit"
for l in '## Judge (Codex), 1 round(s), verdict VERIFIED' '## Verification gate, 1 cycle(s), result pass' 'cycle 1: review break-it (claude-opus-5-5): 1 block(s), 0 note(s); verifier: 0 reproduced' '- pre-existing a.js:1: always fails (exit 1 at head, 1 at base; `false`)'; do
  jq -r .body "$t/prs-g" | grep -qxF -e "$l" || { echo "FAIL: gh7 PR body lacks: $l"; jq -r .body "$t/prs-g"; exit 1; }; done
rc=$(RUN_REPO=o/r STUB_INSTALL_404=1 run gh2 VERIFIED); m=$(ls -d "$runs"/*-gh2 | tail -1)
check "$rc" 1 "gh2 exit (404 fails closed)"; grep -q 'not installed on o/r' "$t/gh2.out" || { echo "FAIL: gh2 404 message"; cat "$t/gh2.out"; exit 1; }
check "$(jq -r .installation_id "$m/manifest.json")" null "gh2 no installation recorded"; check "$(jq -r .base_sha "$m/manifest.json")" null "gh2 never cloned"
# A failed PR open exits 4 and leaves the HTTP status and body in the log and the manifest, so the operator can tell why.
rc=$(RUN_REPO=o/r STUB_PR_FAIL=1 run gh3 VERIFIED); m=$(ls -d "$runs"/*-gh3 | tail -1)
check "$rc" 4 "gh3 exit (PR open failed)"; check "$(jq -r .pr_url "$m/manifest.json")" null "gh3 no PR"; check "$(jq -r '"\(.outcome) \(.class)"' "$m/manifest.json")" "pr_failed infra" "gh3 a failed PR open is pr_failed, infra"
check "$(jq -r .pr_error.status "$m/manifest.json")" 422 "gh3 pr_error.status in manifest"
check "$(jq -r .pr_error.body "$m/manifest.json" | jq -r '.errors[0].message')" "A pull request already exists for o:factory/gh3." "gh3 pr_error.body in manifest"
jq -r 'select(.event.type=="factory") | .event.text' "$m/log.jsonl" | grep -q 'POST /repos/o/r/pulls failed: HTTP 422 .*already exists' || { echo "FAIL: gh3 status/body not in log"; cat "$m/log.jsonl"; exit 1; }
! grep -q 'stub-installation-token' "$m/log.jsonl" "$m/manifest.json" || { echo "FAIL: gh3 token leaked"; exit 1; }
# In a batch, pr_failed (exit 4) is a pass for the chain: judged, pushed, only the PR missing. Both tasks go to done/, 020 is cut from 010,
# the batch exits 0, and each sends a line saying to open the PR by hand.
mkdir -p "$t/p4"; task o/r main 010-p4-a "$body" "$t/p4"; task o/r main 020-p4-b "$body" "$t/p4"
rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_PR_FAIL=1 FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/p4" "VERIFIED,VERIFIED")
check "$rc" 0 "exit 4 chains: batch exit"; check "$(moved p4/done)" "010-p4-a.json 020-p4-b.json " "exit 4 chains: both in done/"
m=$(ls -d "$runs"/*-020-p4-b | tail -1); check "$(jq -r '"\(.chain_base) \(.exit_status)"' "$m/manifest.json")" "factory/010-p4-a 4" "exit 4 chains: 020 cut from 010"
check "$(sed -E 's/^batch-[0-9]+T[0-9]+Z: //' "$t/notify")" "010-p4-a exited 4 (PR open failed, open it by hand, continuing)
020-p4-b exited 4 (PR open failed, open it by hand, continuing)
done: 2 run, 0 PR(s), 0 failed. All tasks ran." "exit 4 chains: a line per task, none failed"; rm -f "$t/notify"
# gate_pending is infra: the attempt is archived and retried once as -i1, which gates clean and passes.
mkdir -p "$t/gp"; task o/r main 010-gp-a "$body" "$t/gp"; rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_REVIEW=crash,none batch "$t/gp" "VERIFIED,VERIFIED")
check "$rc" 0 "gate_pending retry: recovered"; check "$(moved gp/failed)" "010-gp-a.json " "gate_pending retry: the attempt archived"; check "$(moved gp/done)" "010-gp-a-i1.json " "gate_pending retry: the retry passed"
m=$(ls -d "$runs"/*-010-gp-a | tail -1); check "$(jq -r '"\(.outcome) \(.class) \(.pushed)"' "$m/manifest.json")" "gate_pending infra true" "gate_pending retry: original classed infra"
# Chain against GitHub: 020 cuts its branch from factory/010-gc-a but both PRs are opened with base main (the task's own base_branch),
# so a chain head merged and auto-deleted while the next task runs cannot make POST /pulls 422 "base ref not found".
mkdir -p "$t/gc"; task o/r main 010-gc-a "$body" "$t/gc"; task o/r main 020-gc-b "$body" "$t/gc"
rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_PRS="$t/prs" FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/gc" "VERIFIED,VERIFIED")
check "$rc" 0 "gh chain exit"; check "$(jq -r .base "$t/prs" | tr '\n' ' ')" "main main " "gh chain PRs both target main"
check "$(sed -E 's/^batch-[0-9]+T[0-9]+Z: //' "$t/notify")" "done: 2 run, 2 PR(s), 0 failed. All tasks ran." "summary counts the PRs opened (no per-task line: both passed)"; rm -f "$t/notify"
check "$(jq -r .head "$t/prs" | tr '\n' ' ')" "factory/010-gc-a factory/020-gc-b " "gh chain PR heads"
check "$(grep -c 'saw key \[REDACTED\]' "$t/prs")" 2 "gh chain PR bodies carry the redacted review"; ! grep -q 'ghs_yyyy' "$t/prs" || { echo "FAIL: shaped token leaked into a PR body"; exit 1; }
m=$(ls -d "$runs"/*-020-gc-b | tail -1); check "$(jq -r '"\(.base_branch) \(.chain_base)"' "$m/manifest.json")" "main factory/010-gc-a" "gh chain 020 manifest"
git -C "$t/remote.git" merge-base --is-ancestor refs/heads/factory/010-gc-a refs/heads/factory/020-gc-b || { echo "FAIL: gh chain 020 not cut from 010"; exit 1; }
# An ambiguous POST /pulls (422 "already exists", or a 201 whose body has no URL) is reconciled against the open PR from this head: exit 0, URL recorded.
# depends_on against GitHub: merged means a merged PR from the head factory/<id> (any of its -r<N>/-i<N> heads) and no merged
# `Revert "factory: <id>"` PR; an open PR is a wait; reverted is dead. The check mints a read-only token (pull_requests:read, contents:read).
mkdir -p "$t/gd"; task o/r main 010-gd-a "$body" "$t/gd"; rc=$(STUB_APP_KEY="$t/app-key.b64" batch "$t/gd" VERIFIED); check "$rc" 0 "gd night 1"
taskd o/r main 020-gd-b "$body" "$t/gd" '["010-gd-a"]'; taskd o/r main 025-gd-b2 "$body" "$t/gd" '["010-gd-a"]'
rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_MINTS="$t/mints-gd" STUB_MERGED="010-gd-a" batch "$t/gd" "VERIFIED,VERIFIED")
check "$rc" 0 "gd merged: exit"; check "$(moved gd/done)" "010-gd-a.json 020-gd-b.json 025-gd-b2.json " "gd merged: both dependants ran"
check "$(grep -c '"pull_requests":"read"' "$t/mints-gd")" 1 "gd merged: one read-only token for the night, cached in the lock dir, not one per check"
check "$(head -1 "$t/mints-gd" | jq -c '.permissions')" '{"pull_requests":"read","contents":"read"}' "gd merged: the dependency check's token is read-only"
taskd o/r main 030-gd-c "$body" "$t/gd" '["010-gd-a"]'; rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_OPEN="010-gd-a" batch "$t/gd" VERIFIED)
check "$rc" 0 "gd open: exit"; check "$(moved gd)" "030-gd-c.json done " "gd open: waits"; grep -q 'waiting on 010-gd-a (open) |' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: gd open row"; exit 1; }
# Held by deep lint (a requeue, 010-gd-a-r1) beside an earlier attempt's open PR: dead (is_dead), not a live wait, and the dead wait decides the exit.
mkdir -p "$t/gd/held"; task o/r main 010-gd-a-r1 "$body" "$t/gd/held"; echo "contradiction: r" > "$t/gd/held/010-gd-a-r1.reason"
rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_OPEN="010-gd-a" batch "$t/gd" VERIFIED); rm -rf "$t/gd/held"
check "$rc" 1 "gd held beside an open PR: dead"; grep -q 'waiting on 010-gd-a (dead): held: contradiction: r |' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: gd held row"; cat "$t/batch.out"; exit 1; }
rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_MERGED="010-gd-a" STUB_REVERTED="010-gd-a" batch "$t/gd" VERIFIED)
check "$rc" 1 "gd reverted: dead"; grep -q 'waiting on 010-gd-a (reverted): its merge was reverted |' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: gd reverted row"; cat "$t/batch.out"; exit 1; }
# A revert of a different PR whose id shares the prefix (the phrase search returns it) is not this one's revert: still merged.
rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_MERGED="010-gd-a" STUB_REVERTED="010-gd-a-r1" batch "$t/gd" VERIFIED); check "$rc" 0 "gd revert of another PR: merged (exact title)"; check "$(moved gd)" "done " "gd revert of another PR: the dependant ran"
# GitHub errors are never a verdict: a 502 on the PR list or a 403 on the revert search is "unknown": a wait, notified, exit 0. A PR merged
# into another branch than the task's base is not on the base: dead, with the branch named.
taskd o/r main 040-gd-d "$body" "$t/gd" '["010-gd-a"]'; rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_PULLS_FAIL=1 FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/gd" VERIFIED)
check "$rc" 0 "gd 502: a wait"; grep -q '040-gd-d waiting on 010-gd-a (unknown): GitHub answered HTTP 502 on the PRs of factory/010-gd-a' "$t/notify" || { echo "FAIL: gd 502 notify"; cat "$t/notify"; exit 1; }; rm -f "$t/notify"
rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_MERGED="010-gd-a" STUB_SEARCH_FAIL=1 batch "$t/gd" VERIFIED); check "$rc" 0 "gd search 403: a wait, not merged"
grep -q 'waiting on 010-gd-a (unknown): GitHub answered HTTP 403 on the revert search' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: gd search 403 row"; cat "$t/batch.out"; exit 1; }
rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_MERGED="010-gd-a" STUB_MERGED_BASE=release batch "$t/gd" VERIFIED); check "$rc" 1 "gd merged elsewhere: dead"
grep -q 'waiting on 010-gd-a (dead): merged into release, not main' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: gd elsewhere row"; cat "$t/batch.out"; exit 1; }
rc=$(RUN_REPO=o/r STUB_PR_FAIL=1 STUB_PR_LIST=1 run gh4 VERIFIED); m=$(ls -d "$runs"/*-gh4 | tail -1)
check "$rc" 0 "gh4 exit (422 but the PR exists)"; check "$(jq -r .pr_url "$m/manifest.json")" https://github.com/o/r/pull/9 "gh4 existing PR recorded"
jq -r 'select(.event.type=="factory") | .event.text' "$m/log.jsonl" | grep -q 'HTTP 422 but an open PR from factory/gh4 exists' || { echo "FAIL: gh4 reconciliation not logged"; exit 1; }
rc=$(RUN_REPO=o/r STUB_PR_EMPTY=1 STUB_PR_LIST=1 run gh5 VERIFIED); m=$(ls -d "$runs"/*-gh5 | tail -1)
check "$rc" 0 "gh5 exit (201 without html_url, PR exists)"; check "$(jq -r .pr_url "$m/manifest.json")" https://github.com/o/r/pull/9 "gh5 PR recorded"
# The push mint is refused: the run dies with the HTTP status and message, and the manifest already holds the judge's verdict.
rc=$(RUN_REPO=o/r STUB_MINTS="$t/mints6" STUB_MINT_FAIL_AFTER=1 run gh6 VERIFIED); m=$(ls -d "$runs"/*-gh6 | tail -1)
check "$rc" 1 "gh6 exit (push mint refused)"; grep -q 'installation token for o/r (HTTP 401): Bad credentials' "$t/gh6.out" || { echo "FAIL: gh6 mint diagnostics"; cat "$t/gh6.out"; exit 1; }
check "$(jq -r '"\(.judge.verdict) \(.judge.rounds) \(.exit_status)"' "$m/manifest.json")" "VERIFIED 1 1" "gh6 judge state persisted before the failure"
# The merge gate (loop 7 step, merge mode: FACTORY_MERGER_APP_ID set and the task's base_branch is next). A gated pass whose chain base is on
# next: the merger App's token (checks:write, contents:write, pull_requests:write, minted with its own client id) posts factory-gate on the
# head, waits for the PR to be mergeable, merges by sha: merge.state merged with the merge sha, exit 0, the PR targets next. Without
# FACTORY_MERGER_APP_ID nothing is merged (PR-only), with no merge record at all.
git -C "$t/remote.git" update-ref refs/heads/next refs/heads/main
rc=$(RUN_REPO=o/r RUN_BASE=next STUB_MINTS="$t/mints-m" STUB_ISS="$t/iss-m" STUB_PRS="$t/prs-m" FACTORY_MERGER_APP_ID=Iv23merger run m1 VERIFIED); m=$(ls -d "$runs"/*-m1 | tail -1)
check "$rc" 0 "m1 exit"; check "$(g '"\(.merge.state) \(.merge.sha) \(.merge.reason) \(.pr_url) \(.installation_id)"')" "merged m1 null https://github.com/o/r/pull/1 424242" "m1 merged into next; installation_id is still the push App's"
check "$(jq -r .base "$t/prs-m")" next "m1 the PR targets next"; check "$(tail -1 "$t/mints-m" | jq -c .permissions)" '{"checks":"write","contents":"write","pull_requests":"write"}' "m1 the merger token's permissions"
check "$(tr '\n' ' ' < "$t/iss-m")" "Iv23liCLESgW74Wn2Ie2 Iv23liCLESgW74Wn2Ie2 Iv23liCLESgW74Wn2Ie2 Iv23merger " "m1 the merger token's JWT is signed as the merger App (clone, push, PR: the push App)"
grep -q 'merge into next: merged m1' "$m/log.jsonl" || { echo "FAIL: m1 merge not logged"; exit 1; }
rc=$(RUN_REPO=o/r RUN_BASE=next run m0 VERIFIED); m=$(ls -d "$runs"/*-m0 | tail -1); check "$rc" 0 "m0 exit (PR-only)"; check "$(g '.merge // "none"')" none "m0 without a merger App nothing is merged"
# Chain taint: a task cut from a branch that is not on next (an earlier task held for a human) opens its PR and is held. The accumulation cap
# (merges, or changed lines, in next...main) holds too. Every hold says why.
rc=$(RUN_REPO=o/r RUN_BASE=next FACTORY_CHAIN_BASE=factory/m1 FACTORY_MERGER_APP_ID=Iv23merger run m2 VERIFIED); m=$(ls -d "$runs"/*-m2 | tail -1)
check "$rc" 0 "m2 exit"; check "$(g '"\(.merge.state) \(.merge.reason)"' | cut -c1-56)" "held chain base $(git -C "$t/remote.git" rev-parse refs/heads/factory/m1)" "m2 held: chain base not on next"
rc=$(RUN_REPO=o/r RUN_BASE=next STUB_AHEAD=60 FACTORY_MERGER_APP_ID=Iv23merger run m3 VERIFIED); m=$(ls -d "$runs"/*-m3 | tail -1); check "$(g '"\(.merge.state) \(.merge.reason)"')" "held accumulation cap: 60 commits in next...main; promote next first" "m3 held: the cap on commits"
rc=$(RUN_REPO=o/r RUN_BASE=next STUB_LINES=4000 FACTORY_MERGER_APP_ID=Iv23merger run m4 VERIFIED); m=$(ls -d "$runs"/*-m4 | tail -1); check "$(g '"\(.merge.state) \(.merge.reason)"')" "held accumulation cap: 4000 changed lines in next...main; promote next first" "m4 held: the cap on lines"
# A check run that cannot be posted, a refused merge, a PR that never becomes mergeable (bounded wait), a conflict: the PR stays open with the
# reason, exit 0. A lost merge answer is reconciled against the PR: merged, with the merge commit from the PR.
rc=$(RUN_REPO=o/r RUN_BASE=next STUB_CHECK_FAIL=1 FACTORY_MERGER_APP_ID=Iv23merger run m5 VERIFIED); m=$(ls -d "$runs"/*-m5 | tail -1); check "$rc" 0 "m5 exit"; check "$(g '"\(.merge.state) \(.merge.reason)"' | cut -c1-71)" "open check run factory-gate on $(git -C "$t/remote.git" rev-parse refs/heads/factory/m5)" "m5 open: the check could not be posted"
rc=$(RUN_REPO=o/r RUN_BASE=next STUB_MERGE=fail FACTORY_MERGER_APP_ID=Iv23merger run m6 VERIFIED); m=$(ls -d "$runs"/*-m6 | tail -1); check "$(g '"\(.merge.state) \(.merge.reason)"')" 'open merge: HTTP 405 {"message":"Pull Request is not mergeable"}' "m6 open: the merge was refused"
rc=$(RUN_REPO=o/r RUN_BASE=next STUB_MERGE=lost STUB_MERGED_PR=true FACTORY_MERGER_APP_ID=Iv23merger run m7 VERIFIED); m=$(ls -d "$runs"/*-m7 | tail -1); check "$(g '"\(.merge.state) \(.merge.sha) \(.merge.reason)"')" "merged m2 merge answered HTTP 200; the PR reads merged" "m7 a lost merge answer is reconciled"
rc=$(RUN_REPO=o/r RUN_BASE=next STUB_MERGE=lost STUB_PR_GET_FAIL=2 FACTORY_MERGER_APP_ID=Iv23merger run m10 VERIFIED); m=$(ls -d "$runs"/*-m10 | tail -1); check "$rc" 0 "m10 exit"
check "$(g '"\(.merge.state) \(.merge.sha) \(.merge.reason)"')" "unknown null merge answered HTTP 200 and the PR could not be read back (HTTP 502); factory status settles it" "m10 a lost answer that cannot be reconciled is unknown, never open"
rc=$(RUN_REPO=o/r RUN_BASE=next STUB_MERGEABLE=blocked FACTORY_MERGE_WAIT_SEC=0 FACTORY_MERGER_APP_ID=Iv23merger run m8 VERIFIED); m=$(ls -d "$runs"/*-m8 | tail -1); check "$rc" 0 "m8 exit"; check "$(g '"\(.merge.state) \(.merge.reason)"' | sed -E 's/after [0-9]+s/after Ns/')" "timeout PR 1 not mergeable after Ns (mergeable_state blocked)" "m8 timeout leaves the PR open"
rc=$(RUN_REPO=o/r RUN_BASE=next STUB_MERGEABLE=dirty FACTORY_MERGER_APP_ID=Iv23merger run m9 VERIFIED); m=$(ls -d "$runs"/*-m9 | tail -1); check "$(g '"\(.merge.state) \(.merge.reason)"')" "open PR 1 not mergeable (mergeable_state dirty)" "m9 a conflicting PR stays open, saying why"
rc=$(RUN_REPO=o/r RUN_BASE=next STUB_MERGEABLE=unstable FACTORY_MERGER_APP_ID=Iv23merger run m11 VERIFIED); m=$(ls -d "$runs"/*-m11 | tail -1); check "$(g .merge.state)" merged "m11 unstable (only non-required checks failing) merges"
! grep -q 'stub-installation-token' "$m/log.jsonl" "$m/manifest.json" || { echo "FAIL: m9 token leaked"; exit 1; }
# The batch in merge mode checks that main is contained in next first: diverged stops the batch before anything runs, with a notification.
mkdir -p "$t/mm"; task o/r next 010-mm-a "$body" "$t/mm"; rc=$(STUB_APP_KEY="$t/app-key.b64" STUB_CONTAIN=diverged FACTORY_MERGER_APP_ID=Iv23merger FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify" batch "$t/mm" VERIFIED)
check "$rc" 1 "merge mode: main not in next stops the batch"; check "$(moved mm)" "010-mm-a.json " "merge mode: nothing ran"; grep -q 'stopped: main is not contained in next on o/r (compare next...main: diverged, HTTP 200)' "$t/notify" || { echo "FAIL: containment notify"; cat "$t/notify"; exit 1; }; rm -f "$t/notify"
rc=$(STUB_APP_KEY="$t/app-key.b64" FACTORY_MERGER_APP_ID=Iv23merger batch "$t/mm" VERIFIED); check "$rc" 0 "merge mode: main in next, the batch runs"; grep -q '^merge mode: main is in next on o/r (behind)$' "$t/batch.out" || { echo "FAIL: containment message"; exit 1; }
m=$(ls -d "$runs"/*-010-mm-a | tail -1); check "$(g .merge.state)" merged "merge mode: the batch's task merged"
# ruleset-check against the stubs: the local remote refuses a push to next (a pre-receive hook stands in for the ruleset), the stub API answers
# the sequence (405 without the check, the rules name factory-gate, 201 for the check, 409 stale, 200 merged, 422 approval, 405 on main, 200
# close): every line PASS, exit 0.
printf '#!/bin/sh\nwhile read o n r; do [ "$r" != refs/heads/next ] || { echo "refused: next" >&2; exit 1; }; done\n' > "$t/remote.git/hooks/pre-receive"; chmod +x "$t/remote.git/hooks/pre-receive"
set +e; out=$(PATH="$t/bin:$PATH" STUB_APP_KEY="$t/app-key.b64" STUB_STATE="$t/state-rc" STUB_RC=1 STUB_RC_BASE="$(git -C "$t/remote.git" rev-parse refs/heads/next)" FACTORY_SECRETS_DIR="$t/secrets" FACTORY_MERGER_APP_ID=Iv23merger FACTORY_MERGE_WAIT_SEC=0 "$here/factory" ruleset-check o/r 2>&1); rc=$?; set -e
check "$rc" 0 "ruleset-check exit"; check "$(printf '%s\n' "$out" | grep -c '^PASS:')" 8 "ruleset-check: eight PASS lines"; check "$(printf '%s\n' "$out" | grep -c '^FAIL:')" 0 "ruleset-check: no FAIL"
printf '%s\n' "$out" | grep -q '^PASS: the push token cannot push to next$' && printf '%s\n' "$out" | grep -q '^PASS: a merge with a stale sha is 409$' || { echo "FAIL: ruleset-check lines: $out"; exit 1; }
rm -f "$t/remote.git/hooks/pre-receive"; git -C "$t/remote.git" update-ref -d refs/heads/next
# The PR of a revised task opens with why it was revised and the task as first written.
mkdir -p "$t/rp"; task o/r main 010-rp-a "$body" "$t/rp"
rc=$(FACTORY_REVISE=1 STUB_APP_KEY="$t/app-key.b64" STUB_PRS="$t/prs-rp" STUB_WORK_BLOCKED=010-rp-a batch "$t/rp" "VERIFIED"); check "$rc" 0 "revised PR: exit"
check "$(jq -r .body "$t/prs-rp" | sed -n '3,11p')" '## Task revised by the factory (read before merging)

Done when needs x.js; Scope lists s.

Scope: s -> Scope: s, x.js

<details><summary>The task as first written</summary>

Goal: g.' "revised PR: the body opens with the reason, the changes and the task as first written"
check "$(jq -r .revised "$(ls -d "$runs"/*-010-rp-a-r1 | tail -1)/manifest.json")" true "revised PR: recorded in the manifest"
# Model text in a revised task's PR cannot open an HTML comment over the rest of the body.
mkdir -p "$t/rq2"; task o/r main 010-rq2-a "$body" "$t/rq2"
rc=$(FACTORY_REVISE=1 STUB_REVISE=html STUB_APP_KEY="$t/app-key.b64" STUB_PRS="$t/prs-rq2" STUB_WORK_BLOCKED=010-rq2-a batch "$t/rq2" "VERIFIED"); check "$rc" 0 "revised PR, html: exit"
check "$(jq -r .body "$t/prs-rq2" | grep -c '<!--') $(jq -r .body "$t/prs-rq2" | grep -c 'Done when &lt;!-- needs x.js.')" "0 2" "revised PR: < is escaped in the reason and in the revised instructions"
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0; rm -rf "${runs:?}"/*-gh[0-9] "${runs:?}"/*-m[0-9] "${runs:?}"/*-m1[0-9]

# factory stop while docker is down still signals, logs and records the incident instead of dying after writing HALT.
mkdir -p "$runs/stoptest"; echo '{"ended_at":null,"exit_status":null}' > "$runs/stoptest/manifest.json"; : > "$runs/stoptest/log.jsonl"
PATH="$t/bin:$PATH" STUB_DOCKER_PS_FAIL=1 "$here/factory" stop stoptest > "$t/stop.out" 2>&1 || { echo "FAIL: stop with docker down exited $?"; cat "$t/stop.out"; exit 1; }
check "$(jq -r '"\(.exit_status) \(.outcome) \(.class)"' "$runs/stoptest/manifest.json")" "137 stopped task" "stop with docker down records the incident; a stopped task is class task (never re-dispatched by the batch)"; rm -f "$here/HALT"; rm -rf "$runs/stoptest"
# Chain base by commit: a human merges 010's PR mid-batch and GitHub deletes factory/010 (2026-11-05 lost 051b and 052c to this).
# 020 is cut from 010's recorded commit, the manifest says so, and the chain goes on.
queue cs 010-cs-a 020-cs-b
rc=$(STUB_MERGE_PREV=010-cs-a STUB_REMOTE="$t/remote.git" batch "$t/cs" "VERIFIED,VERIFIED")
check "$rc" 0 "chain by commit exit"; check "$(moved cs/done)" "010-cs-a.json 020-cs-b.json " "chain by commit done/"
m10=$(ls -d "$runs"/*-010-cs-a | tail -1); m20=$(ls -d "$runs"/*-020-cs-b | tail -1)
check "$(jq -r .chain_sha "$m20/manifest.json")" "$(jq -r .final_sha "$m10/manifest.json")" "chain by commit: 020 carries 010's final commit"
check "$(jq -r '"\(.chain_base) \(.chain_sha_used) \(.base_sha == .chain_sha)"' "$m20/manifest.json")" "factory/010-cs-a true true" "chain by commit: 020 built on it after the branch vanished"
git -C "$t/remote.git" rev-parse -q --verify refs/heads/factory/010-cs-a >/dev/null && { echo "FAIL: chain by commit: the stub did not delete the branch"; exit 1; }
git -C "$t/remote.git" merge-base --is-ancestor "$(jq -r .final_sha "$m10/manifest.json")" refs/heads/factory/020-cs-b || { echo "FAIL: chain by commit: 020 not cut from 010's commit"; exit 1; }
git -C "$t/remote.git" update-ref refs/heads/main "$(git -C "$t/remote.git" rev-parse refs/heads/main~1)" 2>/dev/null || true   # main back where the other cases expect it
# Chain base behind main: an unrelated PR lands on main after 010 ran (2026-11-06: 083 never saw the image pins merged mid-batch).
# 020's base is 010's branch with main's tip merged in; its branch contains the new file; the merge is not counted as 020's commits.
queue cm 010-cm-a 020-cm-b
rc=$(STUB_ADVANCE_MAIN=010-cm-a STUB_REMOTE="$t/remote.git" batch "$t/cm" "VERIFIED,VERIFIED")
check "$rc" 0 "chain behind main exit"; check "$(moved cm/done)" "010-cm-a.json 020-cm-b.json " "chain behind main done/"
m=$(ls -d "$runs"/*-020-cm-b | tail -1); mainsha=$(git -C "$t/remote.git" rev-parse refs/heads/main)
check "$(jq -r '"\(.base_merged) \(.base_merge_conflict // "none")"' "$m/manifest.json")" "$mainsha none" "chain behind main: 020's manifest records the merge"
git -C "$t/remote.git" cat-file -e "refs/heads/factory/020-cm-b:pins.md" || { echo "FAIL: chain behind main: 020's branch lacks main's pins.md"; exit 1; }
git -C "$t/remote.git" merge-base --is-ancestor "$mainsha" refs/heads/factory/020-cm-b || { echo "FAIL: chain behind main: main's tip not in 020's branch"; exit 1; }
git -C "$t/remote.git" update-ref refs/heads/main "$mainsha~1"   # main back where the other cases expect it
# Scope note: the worker commits docs/SCOPE-<id>.md beside its change; the PR opens, the manifest and the report say so, and the phone is told.
queue sn 010-sn-a
rc=$(STUB_SCOPE_NOTE=010-sn-a FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify-sn" batch "$t/sn" "CAVEATS")
check "$rc" 0 "scope note exit"; check "$(jq -r .scope_note "$(ls -d "$runs"/*-010-sn-a | tail -1)/manifest.json")" true "scope note in the manifest"
grep -q 'scope note in the PR' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: scope note report row"; cat "$t/batch.out"; exit 1; }
grep -q 'opened its PR with a scope note' "$t/notify-sn" || { echo "FAIL: scope note notification"; cat "$t/notify-sn"; exit 1; }

# Base health: the base's own lint script fails at its tip. Deep lint (which owns the base clone) exits 15 before any model runs,
# the batch stops before any task, notifies, and the night is not green. Last, since it rewrites the shared remote's main.
( cd "$t/seed" && git pull -q origin main && printf '{"name":"t","version":"0.0.0","private":true,"scripts":{"lint":"exit 3"}}\n' > package.json && npm install --package-lock-only --ignore-scripts --silent >/dev/null 2>&1 && git add -A && git -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -qm red && git push -q origin HEAD:main )
queue hr 010-hr-a
rc=$(FACTORY_DEEP_LINT=1 FACTORY_NOTIFY_URL=http://notify.test/hook STUB_NOTIFY="$t/notify-hr" batch "$t/hr" "VERIFIED")
check "$rc" 15 "base red exit"; check "$(moved hr)" "010-hr-a.json " "base red: nothing ran, the queue is untouched"
check "$(jq -r .health.result "$(ls -d "$runs"/*-deep-lint | tail -1)/manifest.json")" red "base red: the deep-lint manifest says red"
grep -q '^Stopped: the base is red: ' "$(ls "$runs"/batch-*.md | tail -1)" || { echo "FAIL: base red report"; cat "$t/batch.out"; exit 1; }
grep -q ': stopped: the base is red' "$t/notify-hr" || { echo "FAIL: base red notification"; cat "$t/notify-hr"; exit 1; }
rc=$(FACTORY_DEEP_LINT=1 FACTORY_HEALTH=0 FACTORY_GATE=0 batch "$t/hr" "VERIFIED"); check "$rc" 0 "FACTORY_HEALTH=0 skips the check"
find "$runs" -mindepth 1 -maxdepth 1 -newer "$t/secrets" -exec rm -rf {} +   # everything the run tree gained since this test began is the test's (the lock keeps a real run out)
echo "ok: revisions (a blocked task rewritten, reviewed and rerun the same night; deep lint rewrites; the PR shows the original), egress (per-step proxy, allowlists, network record, dead proxy, lost record), pins (image id, models, no spend cap), cost per round and report, evidence error (worker, judge), redaction (encoded, by shape: log, judge file, PR body), supply chain (credential in tree, in task, in lint; dependency manifest gate and its Scope permission; npm policy; requeue notes), judge loop (revise with facts and claims apart, refuted, no verdict, caveats, failed revision, idle revision, redaction, CRLF/double/oversize verdicts, judged-round count, five rounds, App bot commit identity and its failed lookup), verification gate (clean gate ships with the record in the PR body; pre-existing, invalid and truncated never block; a regression and an unmet clause cost one worker round with the facts, one judge round with the facts and a re-gate; crashed or invalid review, crashed verifier, a stop during the review are gate_pending and retried as -i1; a failed second push keeps the first; no new commits, the same repro twice, REFUTED in a cycle and the MAX_GATES ceiling are refuted by the gate; blocked and conflict never reach it; the differential test checks with npm ci), gates (blocked: round-1 note skips the judge, note on code, note in round 2 after REFUTED and after CAVEATS, deleted note, a directory is not a note, a replace ref does not skip the judge, manifest ahead of blocked; the worker prompt names the note path; conflict with the target), lint, batch (chain, refuted chain, chain after a failure, max-tasks, stop-at, halt, no-chain, continue, declared dependency, killed run left in queue, blocked reason on the phone, notify host and off state, failed POST visible, infra retry recovered / failed the same way / conflict cut from its own base / conflict mid-chain not retried, hand-queued -i1 after a pass, circuit breaker, pr_failed chains, a stopped run is class task, depends_on: passed tonight / not merged waits / merged runs / no-chain waits / queued waits / dead notified and non-zero / pruned record unknown / worst dependency decides / declared base waiting / GitHub merged, open, reverted by exact title, 502 and 403 unknown, merged elsewhere dead / one cached read-only token), class and pushed in the manifest, lint depends_on (graph, later, self, unknown, other repo, schema, id grammar, malformed archive), requeue (blocked, refuted, skipped), GitHub App (installation lookup, 404, failed PR open, PR reconciliation, refused mint, chained PRs target base_branch), merge gate (merged into next by the merger App; PR-only without it; held on chain taint and on the cap; open on a failed check post, a refused merge, a timeout, a conflict; a lost answer reconciled; the batch's main-in-next check; ruleset-check against the stubs), deep lint (additions in place with the host's paragraph, a dropped id refused, holds with reason and proposal, a later supplier held for reordering, a held dependency known to lint and a dead wait in the batch, all held is exit 10 and notified, an invalid answer and a proposal that fails lint change nothing, a queue that fails lint never reaches the container, a failed deep lint falls through to the deterministic lint, notified), unhold (back under its own id, touch recorded, refused outside held/, over a queued file, when the queue would fail lint, while a batch holds the lock; a failed copy keeps the held files), a held dependency dead ahead of an open PR, .proposed ids reserved, a deep lint that dies while applying says so, stop with docker down, chain base by commit after a mid-batch merge, chain base behind main merged in, scope note in the PR and on the phone, requeue from a source spec, red base stops the night (exit 15, FACTORY_HEALTH=0)"
