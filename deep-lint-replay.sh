#!/bin/bash
# deep-lint-replay.sh <keycard-workshop-platform checkout> [prompt-file]: the scored replay of deep lint (docs/cascade-plan.md, loop 1).
# Sends the deep-lint prompt through Codex, the way `factory lint --deep` does, over the 16 tasks of the 2026-11-03 night (each as its
# -r1, with the rest of factory-tasks/ archived in done/), against main as that night saw it, and scores the answer: the 11 tasks that
# blocked must be flagged (a depends_on addition or a hold, of the expected kind), the 5 that passed must not be held. Exit 0 on target.
# Not hermetic: a real model on the operator's own Codex login, run by hand when the prompt or JUDGE_MODEL changes. test-factory.sh
# covers what the host does with the answer. ponytail: the host's own Codex, not the container: same CLI version, model and prompt; the
# container's AGENTS.md strip and egress are the host's to test, not the prompt's.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; repo="${1:?usage: deep-lint-replay.sh <keycard-workshop-platform checkout> [prompt-file]}"; prompt_file="${2:-$here/deep-lint-prompt.md}"
SHA=bcbf690   # main when the 2026-11-03 batch started (17:38Z); every -r1 branch of that night was cut from it
model=$(sed -n 's/^JUDGE_MODEL="\(.*\)"$/\1/p' "$here/factory")
# id, what the night's BLOCKED note says, expected: add:<ids> (prerequisites some task supplies: depends_on gains them, the task waits),
# hold (a prerequisite no task supplies, a contradiction, an ambiguity, a blank human input), or pass (ran clean: never held).
cases='053-wp-web-terminal-tab add:052a
054-wp-web-agent-pane hold
055a-wp-web-steps-and-check hold
055b-wp-web-restore-and-mode add:052a,052b,054
055c-wp-web-keycard-and-hand hold
056a-wp-web-admin-events pass
056b-wp-web-admin-hooks-facilitators hold
057-wp-web-facilitator-console add:052a,053
070-wp-workshop-ui-starlight-and-bridge pass
071a-wp-workshop-ui-port-static-components hold
071b-wp-workshop-ui-port-interactive-components pass
072a-wp-workshop-ui-check-and-restore pass
072c-wp-workshop-ui-mode-and-var pass
072d-wp-workshop-ui-step-text-emitter hold
082-wp-phase1-acceptance-scenario add:019c
083-wp-base-image hold'
t=$(mktemp -d "${TMPDIR:-/tmp}/deep-lint-replay.XXXXXX"); echo "replay dir: $t"
git -C "$repo" cat-file -e "$SHA^{commit}" || { echo "$repo has no commit $SHA; fetch it first" >&2; exit 2; }
git clone -q --no-checkout --shared "$repo" "$t/base"; git -C "$t/base" checkout -q --detach "$SHA"
mkdir -p "$t/queue/done"; queued=" "
while read -r id _; do queued="$queued$id "
  git -C "$repo" show "$SHA:factory-tasks/$id.json" | jq --arg id "$id-r1" '.task_id=$id' > "$t/queue/$id-r1.json"; done <<< "$cases"
for f in $(git -C "$repo" ls-tree --name-only "$SHA" factory-tasks/ | grep '\.json$'); do id=$(basename "$f" .json)
  case "$queued" in *" $id "*) ;; *) git -C "$repo" show "$SHA:$f" > "$t/queue/done/$id.json" ;; esac; done
# The Inputs section as cmd_deep_lint writes it, with this replay's paths for /queue and the base. Keep the two in step.
prompt="$(cat "$prompt_file")"$'\n\n'"## Inputs"$'\n'"Base: main at $(git -C "$t/base" rev-parse HEAD), your working directory."$'\n'"Queue directory: $t/queue (read-only). Tasks, in order: $(cd "$t/queue" && ls *.json | sed 's/\.json$//' | tr '\n' ' ')"
if [ -n "${DEEP_LINT_ANSWER:-}" ]; then cp "$DEEP_LINT_ANSWER" "$t/out.md"; echo "scoring $DEEP_LINT_ANSWER"   # rescore a saved answer, no model call
else
  echo "codex $model on $(echo "$cases" | wc -l | tr -d ' ') tasks at $SHA ($(date -u +%H:%M:%SZ))"; t0=$(date +%s)
  codex exec --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check -c project_doc_max_bytes=0 -m "$model" \
    --sandbox read-only -C "$t/base" -o "$t/out.md" "$prompt" < /dev/null > "$t/codex.log" 2>&1 || { echo "codex failed; see $t/codex.log" >&2; exit 2; }
  echo "answered in $(( $(date +%s) - t0 ))s"
fi
sed '1{/^```/d;}; ${/^```$/d;}' "$t/out.md" > "$t/out.json"   # the same fence strip as the host
jq -e '.tasks|type=="array"' "$t/out.json" >/dev/null || { echo "no JSON answer; see $t/out.md" >&2; exit 2; }
# Scored by what the batch would have done that night. An addition counts only if it makes the task wait: a queue task that did not pass
# that night, or an archived task whose work is not on the base (no merge commit from its branch, no branch of it an ancestor of SHA). An
# addition of anything else is satisfied at once and the task runs and blocks as it did. "flagged": the task would not have run that night.
onbase=" $(git -C "$repo" log "$SHA" --merges --format=%s | sed -n 's/.*from [^/]*\/factory\///p' | sed -E 's/(-[ri][0-9]+)+$//' | tr '\n' ' ')"
for f in "$t/queue/done"/*.json; do id=$(basename "$f" .json)
  for b in $(git -C "$repo" for-each-ref --format='%(refname)' "refs/remotes/origin/factory/$id" "refs/remotes/origin/factory/$id-*"); do
    ! git -C "$repo" merge-base --is-ancestor "$b" "$SHA" || { onbase="$onbase$id "; break; }; done; done
satisfied="$onbase$(echo "$cases" | awk '$2=="pass"{print $1}' | tr '\n' ' ')"
printf '%-50s %-20s %-34s %s\n' TASK EXPECTED GOT SCORE; flagged=0 kind=0 falsehold=0 falsewait=0
while read -r id want; do
  r=$(jq -c --arg id "$id-r1" '[.tasks[] | select(.task_id==$id)] | first // {}' "$t/out.json")
  w=; for d in $(jq -r '(.depends_on // [])[] | sub("(-[ri][0-9]+)+$"; "")' <<< "$r"); do case "$satisfied" in *" $d "*) ;; *) w="$w,${d%%-*}" ;; esac; done; w=${w#,}   # waiting additions, by number
  hk=$(jq -r '.hold.kind // empty' <<< "$r"); got="${w:+waits:$w}${hk:+ hold:$hk}"; got=${got# }
  case "$want" in
    pass) if [ -n "$hk" ]; then s="FALSE HOLD"; falsehold=$((falsehold+1)); elif [ -n "$w" ]; then s="false wait"; falsewait=$((falsewait+1)); else s=ok; fi ;;
    hold) if [ -n "$hk" ]; then s=caught; flagged=$((flagged+1)); kind=$((kind+1)); elif [ -n "$w" ]; then s="waits, not held"; flagged=$((flagged+1)); else s=MISSED; fi ;;
    add:*) miss=; for n in $(tr , ' ' <<< "${want#add:}"); do case ",$w," in *",$n,"*) ;; *) miss="$miss $n" ;; esac; done
           if [ -n "$hk" ]; then s="held instead"; flagged=$((flagged+1)); elif [ -z "$w" ]; then s=MISSED
           else flagged=$((flagged+1)); if [ -z "$miss" ]; then s=caught; kind=$((kind+1)); else s="waits, lacks$miss"; fi; fi ;;
  esac
  printf '%-50s %-20s %-34s %s\n' "$id-r1" "$want" "${got:--}" "$s"
done <<< "$cases"
echo "flagged $flagged/11 (expected action $kind/11), false holds $falsehold/5, false waits $falsewait/5; answer: $t/out.json"
[ "$flagged" -eq 11 ] && [ "$falsehold" -eq 0 ]
