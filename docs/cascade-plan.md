# Factory plan: verification, repair and flow, so the operator can walk away

## Status (2026-11-02)

Landed on `main`, one line each:

- Parity 1, egress allowlist on a per-run internal network: PR #42.
- Parity 2, target-repo rulesets so the push token reaches only `factory/**`: on `keycard-workshop-platform` since 2026-10-31.
- Parity 3 to 5, credential screening, the dependency-manifest gate, npm policy: PR #43.
- Parity 6 to 9, image pin, model pins, cost record, evidence fails closed, redaction by shape: PR #44. Still in the code
  and to drop: the worker's `--max-budget-usd` (decided 2026-11-02: no spend ceiling; the cost record stays).
- This plan; the judge's test-a-claim rule (31edc5f); loop 2 (task or infra, `pushed`, one `-i1` retry, circuit breaker,
  `stopped` is class task, notify state); loop 3 (`depends_on`, lint graph rules, `dep_state`, waits in place, dead waits
  notified and non-zero): PR #45.
- Of the 2026-11-01 handoff, items 1, 2, 8 and 9 are closed by the above; items 4 to 7 are task-file fixes in the workshop
  repo (two patches on the laptop), not factory code.

Next, in order, one branch and one PR each, merged before the next starts:

1. Loop 4: the worker's BLOCKED note ends the run before the judge; the note-at-head gate; gate order (`gt`, manifest,
   blocked); the fact-separated judge prompt (orchestrator facts apart from prior claims, REPEAT re-established at head).
2. Loop 0 in PR-only mode: the `review` and `verify` entrypoint arms, the gate after the push and the cheap gates, JSON
   findings, regression-or-unmet, gate cycles with their own counter, `gate_pending` as infra, an image rebuild.
3. Loop 7's canary queue and the negative ruleset tests; then the merge into `next` with chain taint, `scope_widened` and
   the accumulation cap. **Before this step is enabled, with the operator: the `next` ruleset on the target repo and a
   separate merger App with its Keycard resource (parity, not yet started). Until they exist the gate stays in PR-only
   mode.**
4. Loop 1 (deep lint: additions and holds only, `held/`, `unhold`) and loop 6 (`factory status`, the `main` ⊆ `next`
   invariant, the revert procedure).
5. Loop 5 (triage with attribution, the revision file, host requeue with locked Goal and Done when and the Scope refusal
   list, one revision ever, the audit paragraph).
6. Loop 7's replay (`factory rejudge`) against last night's branches; then fix cycles may send work back.
7. Parity 10 to 12 (provenance block, hash ledger, harness deny rules): nothing in the loops needs them; after the loops.
8. Parity 13 and the Keycard client secret (the Secure Enclave signer, private_key_jwt, `docs/jwks.json`): last; nothing
   in the loops needs them.

The mini still runs the PR 40 commit. Before the next real night: `git -C ~/software-factory pull --ff-only`, an image
rebuild (the Dockerfile changed in #42; the two-step `IMAGE_ID` rollout in its header), then a smoke batch (`--max-tasks 2`
against the throwaway repo) and a read of the manifests' `class` and `pushed` fields and the `notify:` line.

Goal: the operator leaves the factory running and comes back to finished, verified work. Every failure is repaired by
the line or routed around; every change that ships was checked by reviewers that did not write it and did not review it
before, and every blocking finding was reproduced by a machine; the human is the outermost loop, reached asynchronously,
with the line still moving on everything that does not need them.

Evidence (batch of 2026-11-01, keycard-workshop-platform): 40 tasks, 12 hours. 15 PRs, 18 blocked, 6 refuted, 1 killed.
Two roots did most of the damage. `050b web auth` was refuted for three rounds on a judge claim the judge had not tested
(a tsconfig entry "unnecessary"; TS6307 when it finally tried it in round 4), by which time the worker had reverted a
working implementation and written a BLOCKED note (commit 31edc5f). Then 051 to 057, 081 and 082 each ran up to five rounds
and failed because no signed-in participant exists on the branch: ten tasks, about five hours. `070 workshop-ui` was
refuted five times for the same forbidden dependencies, then 071a to 072d failed on the missing predecessor. `039b`: a
dependency the task forbade. `083`, `039a`: spec gaps. Every root was a spec defect or a judge error visible before or in
round one; nothing acted on it, and the fix was a human editing specs the next day. About five of the twelve hours went
to tasks that could not succeed.

Evidence from the plan's own review (2026-11-02): one reviewer carrying its findings across rounds (Codex, 15) was
followed by eight reviewers with fresh context and distinct lenses, who found about 90 more, many P1 (a chain-taint
bypass of the merge gate, found independently by two of them; a cursor rule wrong by one byte of collation; a failed push
recorded as pushed), and every one was verified against the code before it changed anything. The published results say
the same: prior findings anchor a judge ([arXiv 2608.25869](https://arxiv.org/abs/2608.25869)); one same-model plus one
cross-model review catches more than two same-model reviews ([arXiv 2610.01471](https://arxiv.org/html/2610.01471v2));
models prefer their own output ([arXiv 2404.13076](https://arxiv.org/abs/2404.13076)); the pattern that holds is reviewers
that see only the claim, with empirical reproduction as the gate before promotion
([Refute-or-Promote, arXiv 2604.19049](https://arxiv.org/html/2604.19049v1)). The reference architecture requires every
output checked before it moves on, allows automatic approval, and wants verification results to drive it
([agentbaseline software-factory](https://github.com/agentbaseline/agentbaseline/blob/main/software-factory/software-factory.md)).

The ladder: prevention → code loop → verification gate → attribution (spec, worker, judge, environment) → one of {revise
the spec, a fresh worker, a fresh judge, an infra retry} → human. Each rung has a progress bound; exhaustion escalates one
rung up; the human's fix re-enters the queue. Sideways: a circuit breaker that stops the line, queue intact, when the
failures are systemic. Bounds are on progress and rounds, never on dollars: the operator has said tokens are not the
constraint, working is.

## Principles of verification

1. **Fresh session per review.** No reviewer sees its own earlier findings as its own. The orchestrator holds the ledger
   and hands a later reviewer two separate things: facts it observed itself ("`<repro>` exited 1 at head `<sha>`, 0 at
   base") and model claims, marked untrusted. Executable claims are rerun at the new head; diff claims are re-read and
   cited at the new head; REPEAT means re-established there, after reading the worker's answer and rerunning any command
   it gave (31edc5f). This does not remove anchoring on prose, only on facts; it is why the gate exists.
2. **Independence from the author.** A reviewer sees the task, the diff and the repository, never the worker's
   reasoning. A judge is never the model family that wrote the code; the gate includes a model that is not the loop judge.
3. **Execution is the verdict.** A finding blocks only when a machine reproduced it: the command fails validly at head
   and passes at base (a regression), or fails at both and names a Done when clause (unmet). A command that fails for any
   other reason (not found, timeout, install failed, failed at base with no clause named) is not evidence. A reviewer's
   confidence is not evidence ([arXiv 2505.16222](https://arxiv.org/html/2505.16222v2)).
4. **Missing verification is not approval.** A reviewer that crashed, an invalid output, a verifier that could not set up:
   the gate fails closed as infrastructure, never as a pass.
5. **Every output is checked before it moves.** Code before the PR, the task before the run, the factory before the night.

## Measures

Recorded by `factory status` (loop 6), one line per morning in `runs/status.tsv`, from data something actually records:

- promotions: changes on `next` promoted to `main`, and the promotion PR's open-to-merge time (labelled as that, not as
  effort);
- unplanned touches: `requeue` and `unhold` append a line to `runs/touches.tsv`; hand spec edits are a `job_sha256`
  that differs from the queue file's hash at lint time;
- escaped defects: reverts on `next` (loop 3's query), CI red on `next`, changes rejected at promotion;
- dead compute: worker, judge and gate rounds on tasks whose terminal `outcome` is dead, from the manifests;
- verification: BLOCKs raised versus reproduced, per lens and per reviewer, from `gate` in the manifests.

The third keeps the rest honest; the fifth is how reviewer prompts and models get changed on evidence instead of on the
last incident.

## Loops

### 0. Verification gate: fresh, cross-model, reproduced, after the push and before the PR

Today a branch ships on the word of one Codex judge that carried its own findings across up to five rounds.

**The round loop's judge.** The prompt framing at the "previous findings" header and the REPEAT definition change to
principle 1: orchestrator-verified facts in one section, prior model claims in another, REPEAT only when re-established
at the new head. Not "drop what you cannot reproduce": scope, weakened-test and over-engineering findings are diff facts
and would oscillate out and back in (the 011 lesson); they are re-read and cited instead.

**Where the gate sits.** At loop exit (VERIFIED, or CAVEATS at the last round or on an idle round), **after** the push and
the cheap gates (`gt`, dependency manifest, blocked, conflict) and before `open_pr`, in the `VERIFIED|CAVEATS` arm. The
push first keeps today's evidence rule (the judged head is on GitHub whatever happens next), keeps `$gate` for the
verifier's base and head, and does not spend three containers on a branch the cheap gates would reject.

**Three steps, sequential** (the verifier depends on the reviews; `run_container` is not parallel-safe: `status` is a
global, `die` in a subshell ends only the subshell, `manifest_set` uses `$$` for its temp file, container and proxy names
carry only mode and round):

1. `review`: a Claude reviewer with the *break-it* lens (correctness relative to the task, inputs and states where the
   change is wrong, every Done when clause exercised). A new entrypoint arm: clone `/src` into `/work` at `HEAD_SHA`;
   strip recursively, not at the root only (`find . \( -name CLAUDE.md -o -name CLAUDE.local.md -o -name AGENTS.md -o
   -name AGENTS.override.md -o -name .claude -o -name .codex -o -name .cursor -o -name .mcp.json \) -prune -exec rm -rf
   {} +`); run the pinned CLI with `--safe-mode --setting-sources "" --strict-mcp-config --disable-slash-commands
   --no-session-persistence --allowedTools "Bash,Read,Glob,Grep,Edit" --json-schema <findings schema>` (`--safe-mode`
   disables CLAUDE.md, hooks, MCP, plugins and commands and keeps auth; `--bare` would break the `ANTHROPIC_AUTH_TOKEN`
   path). The flags are the control, the strip the backstop; repo text is still untrusted input. Output: the last
   `result` event written by a `node -e` line (the image has no jq) to `/out/review.json`, failing on `is_error`; the
   CLI's own exit checked separately (`sh` has no pipefail). Needs its own egress case (`review) allow='api\.anthropic\.com|registry\.npmjs\.org'`;
   the mode switch sends unknown modes to the push allowlist today), a `REVIEW_MODEL` pin, the worker's Anthropic token
   fresh for the step, and the prompt file in the existence check at startup. Accepted risk, as for the Codex arm: the
   repo's tests run beside the token.
2. `review` again with the *integrity* lens on Codex (scope, deleted or weakened tests, mocked-away behaviour, helpers
   and fixtures, dependency and lockfile changes, CI and workflow edits, secrets). These are diff facts, not failing
   commands, so this lens produces NOTEs for the PR body and never blocks by itself; the parts that are mechanically
   checkable are host gates (CI and workflow paths in the diff, like the dependency-manifest gate) or verifier checks
   (next step).
3. `verify`: a credential-free container, no model, new arm, egress `registry\.npmjs\.org` only. Findings are JSON, not
   text (`{"blocks":[{"loc","claim","clause","repro"}],"notes":[…]}`; the pipe character made a text grammar unparseable).
   It runs `npm ci` once per checkout (a failure here is a gate error, not a downgrade), then for every BLOCK:
   `bash -o pipefail -c "<repro>"` under `timeout 300` at the clone root, at head and at base, with `git checkout -f && git
   clean -fdx -e node_modules` between runs, recording both exit codes. Classification (principle 3): *invalid* (head
   exit 0, 124, 126, 127, ≥128), *regression* (head fails validly, base passes), *unmet* (both fail and the BLOCK names a
   Done when clause), *pre-existing* (both fail, no clause; a NOTE, as the judge prompt already rules). `expect` is
   "nonzero", not an exact code (jest, vitest, tsc and node differ). Two mechanical lenses run here too, on every gate:
   base's test files against head's code (a base test failing at head is a regression or a test changed under it) and
   head's new or changed tests against base's code (a new test that passes on base tests nothing). Output
   `/out/verify.json`, redacted and bounded on the host before it reaches the PR body.

Each step's output is written to the run dir as it completes (`gate-<cycle>-<lens>.json`, `verify-<cycle>.json`), and the
manifest gets `gate:{cycles:[{reviews:[{lens,arm,model,status}], verifier:{status, blocks:[{claim,repro,head_exit,base_exit,class}]}, reproduced:n}], result}`
persisted after every cycle (outcome rule 4). A step with no output, an invalid file, a crashed container or a failed
install is `gate_error` (12, infra in loop 2) with `gate_pending` in the manifest: the retry is "re-gate `factory/<id>`
at `final_sha`", resumed by the next batch or `factory status`, never a new worker run (principle 4).

**Cycles.** Zero reproduced BLOCKs → the PR (and the merge, below), with both reviews and the verifier record in the body.
Otherwise the reproduced BLOCKs, as orchestrator facts, go to **one** worker round (prompt header: "a verification gate
reproduced these; the loop judge had passed the branch"), then **one** loop-judge round with the facts, then the gate
again, and the fast-forward is re-pushed and re-fetched. Rules: no new commits in a gate cycle means refuted (today's
"the prior verdict stands" would ship over a reproduced BLOCK); REFUTED from the loop judge in a gate cycle means dead,
never back into the round loop; the gate has its own counter, so a loop that passed in round 5 is not blocked by
`MAX_ROUNDS`; `judge.rounds` keeps counting every judged round. Death is on no progress, not on count: dead when a cycle
reproduces a BLOCK whose `repro` already reproduced in an earlier cycle, with a ceiling of four gates. Dead is
`outcome:"refuted", refuted_by:"gate"`, exit 5, no PR, and triage (loop 5) gets the verifier's record to attribute from.

**Time.** On last night's numbers, 15 gates of three sequential containers. If the night runs long, `--stop-at` bounds it
between tasks as today; a gate is never cut mid-way except by the per-container watchdog, which is a gate error.

### 1. Prevention: `factory lint --deep`, additions and holds only

Every root last night was visible before the batch started. The reference architecture says to validate inputs before
the factory acts on them. The reactive loop finds each of these at the cost of a full worker run; lint finds them for the
price of one review.

`factory lint --deep [dir]`, run by `batch` after `take_lock` and before the deterministic lint (never before the lock:
another batch may own the queue): one fresh Codex container (the judge arm with `deep-lint-prompt.md`) with the queue and
a clone of the base branch, read-only. For every task it reports: prerequisites each table, column, export, file, route or
dependency the task relies on exists on the base or is supplied by a named earlier task (→ proposed `depends_on`);
contradictions (Scope cannot contain what Done when needs; Out of scope forbids what Done when needs; a dependency Done
when needs is not named under Scope); ordering (a task that depends on a later one).

**What the host applies, mechanically checked, monotone:** `depends_on` becomes original ∪ proposed, never fewer, in
place under the same id (no branch exists before a run, so `-rN` has no reason to exist here and must not spend the one
revision or the auto-merge), with the provenance paragraph; the proposed queue is then validated whole (deterministic lint:
ids, cycles, unknown ids) and applied transactionally, or not at all, with a notification. A contradiction is **held**:
the file moves to `held/<id>.json` with `held/<id>.reason` beside it and the proposed fix written as `held/<id>.proposed.json`
for the operator to apply; it is notified, counted ("N task(s) held" in the summary and the exit status, never an empty
successful night), and lint treats a held id as known-dead (a wait, not an error). Deep lint never widens Scope, never
removes an Out of scope line, never touches Goal or Done when, never names `package.json`: under the merge gate the base
it reads is `next`, worker-written and not human-read, so a night-1 worker could plant text to steer night-2 lint, and the
only output that cannot be steered into authority is a delay or a hold. If deep lint fails, the night proceeds on
deterministic lint with a notification. `factory unhold <held/file>` moves a task back under its own id after the
operator's edit and records the touch; `requeue` is for tasks that ran. The task generator in the workshop repo emits
`depends_on` as the first source; deep lint is the check on it.

### 2. Task or infra: classify every outcome, retry infra, break the circuit

Today `cmd_batch` moves every non-zero exit to `failed/`, whatever the cause. A token-exchange `die`, a judge that
produced no verdict because npm was down (6), a PR open that failed (4), a gate that could not fetch (12), a stop or
watchdog kill (137), a model pin retired, a workspace limit reached at 2 a.m.: all look like the task's death. Under
`--continue` an outage moves every remaining task to `failed/`; with dependencies each one parks a subtree; and a hand
`requeue` spends the task's one revision on a failure that was never its own.

- Every exit gets `class:"task"|"infra"` in the manifest, set where the outcome is set: task = 3, 5, 10, 13, 14; infra = 1
  with no `outcome` at any point (the only task-caused `die` after round 1 is the branch-name check, which gets an
  outcome), 4, 6, 11 on a passing verdict, 12 (including `gate_error`), 130, 137. A worker container's own exit code
  passes through as the run's status, so the class is decided from `outcome` and the round state, never from the number.
- **Pushed means pushed.** Today `final_sha` is set from `head` before the push and written unconditionally, so a push
  that failed records the judged sha as if it were on GitHub. The push step records `pushed:true|false` and
  `push_status`; `final_sha` is written only when pushed. Loop 2 keys on `pushed`.
- Infra with nothing pushed: the task stays in the queue under its own id. Infra with a pushed branch: one same-night
  retry as `<id>-i1` with `retry_of` in the manifest. The retry's base: the same chain base, except exit 11, whose retry is
  cut from the branch it conflicted with (the same base reproduces the same conflict). A retry that ends with the same
  exit and outcome as its original is a **task** failure: the retry proved it reproducible, and it does not count toward
  the breaker.
- `gate_pending` (a gate step failed): the retry re-gates `final_sha`, no worker.
- Exit 4 on a passing verdict and a clean gate: the branch is pushed, judged and gated; the task goes to `done/`, `prev`
  advances, the batch exit is 0 for it, and `factory status` opens or reports the PR.
- Circuit breaker: two consecutive infra failures **from distinct tasks** stop the batch with everything left in the
  queue untouched and one notification naming both (the per-task lines suppressed on that path).
- **A silent night is diagnosable.** Last night ran without `FACTORY_NOTIFY_URL` (it lives in `.zshrc`, which the
  batch's shell did not read), `notify` returns silently when it is unset, and a failed POST is `curl -s … || true`.
  `batch` prints `notify: <host>` or `notify: off (FACTORY_NOTIFY_URL not set)` after taking the lock and in the report
  header, host only (cut at the first `/`, `?` or `#`, then before `@`, so a token never reaches the log); a failed POST
  prints `notify: POST failed (curl exit N)` to stderr; `test-factory.sh` runs `unset ${!FACTORY_*}` so it is hermetic;
  README and factory.md say the exports live in `.zshenv` (ssh one-liners and launchd read no rc file) and list both
  causes under "if no message arrives". No start-of-batch ping: noise against the quiet-by-design rule.
- One line in `worker-prompt.md`: never kill process groups you did not start (035 killed its own container testing a
  kill-at-deadline change; a retry that does it again is a task failure under the rule above).

### 3. Declared dependencies that wait, with GitHub as the truth for "merged"

An optional field `"depends_on": ["050b-web-auth"]`. `JOB_SCHEMA` gets a second clause (its `all(.[]; type=="string")`
rejects an array), in the one definition `run`, `lint` and `requeue` share. Lint normalises ids to base ids (the `-r<N>` /
`-i<N>` suffix stripped once), prints the graph, and refuses cycles, unknown ids, and **a dependency on a later task in the
queue**: filename order is the schedule, so the generator emits tasks in dependency order and lint says "reorder" instead
of the batch waiting a night (055a to 055c call routes 059b adds; last night's order would have run them first). A
dependency on a failed or held task is a wait, not an error. Only a `wait_for` from triage (loop 5) can point later, and
that one waits until the next night.

Before a task runs, every dependency must be available on the branch the task is cut from:

- passed tonight in chain mode (`passed` set of base ids; the linear chain contains every passed task), or
- merged into `next` and not reverted, as GitHub says: `GET /repos/<r>/pulls?state=all&head=<owner>:factory/<id>` for the
  base id and its `-rN` and `-iN` heads, `merged_at` set on one, and no merged PR into `next` titled `Revert "factory: <id>"`
  (the revert button's title; `open_pr` sets `factory: <id>`). Not the local run record (`runs/` has no retention policy)
  and not an ancestor test alone (a revert leaves the merge commit an ancestor). The mint is `open_pr`'s, lazy, once per
  repo, only when a check needs it; the owner/name normalisation and the App-vs-file token split move out of `cmd_run`
  into a helper; the batch clears `rundir` before minting. The file-token dry run keeps the ancestor test. Under
  `--no-chain` only merged counts, and a dependency's repo must equal the dependent's.

**One predicate, `is_dead <base id>`**, used by the wait here, by `wait_for` in loop 5 and by `factory status`: not in the
queue under any id normalising to it, not in `passed`, not merged-and-unreverted; and in `failed/` or `held/` with no queued
`-rN` or `-iN`, or its `-r1` failed, or reverted, or its PR closed unmerged. The batch keeps `prev` literal (the chain base
is `factory/A-i1`) and `passed`/`failed` as base ids, and the declared-base skip normalises both sides before matching.

Otherwise the task waits: row `waiting on <id>`, file untouched, visited once per night, so a dependency that passes later
the same night releases it the next night. A wait on something dead is its own row, `waiting on <id> (dead: reverted)`,
counts as dead for the batch's exit status, and is notified; a wait older than one night is notified. Last night this
loop alone saves ten web tasks and five UI tasks, about seven hours.

### 4. The worker's BLOCKED note ends the run before the judge

The worker prompt already demands `docs/BLOCKED-<task_id>.md` for a missing prerequisite, and since 31edc5f the judge
reports a check that passes only with an out-of-scope change as blocked in the round it is found. One sentence extends the
worker's rule to a reviewer finding: when a finding can only be satisfied by leaving Scope, adding a dependency the task
forbids, or a prerequisite that is not on the branch, do not attempt it; write the note (first text line the reason, then
what is missing and which task or Scope change would supply it, in prose) and stop.

Three orchestrator edits: after the round's `head` is resolved and the idle check, `git -C "$work" cat-file -e
"$head:docs/BLOCKED-$task_id.md"` breaks the loop with `judged` unchanged (a round-1 note: `judge:{rounds:0,
verdict:null}`, exit 10; the `bk` fixture becomes `VERIFIED` with rounds 0 and verdict null; 18 tasks last night each save
a judge round and an empty worker round). The blocked gate becomes "this task's note exists at `$head`" in `$gate`
(a missing path exits 128; `if … 2>/dev/null`), so a note on top of code is blocked and a deleted or another task's note
is not; a VERIFIED branch carrying this task's note is exit 10 with no PR. The dependency-manifest gate moves ahead of the
blocked gate; the `gt` branch stays first.

### 5. Triage on a dead task: attribute, then act once

A task is dead when the code loop ends refuted (including by the gate), blocked, or on a dependency change. A spec
rewriter applied to every death would bend specs around worker and judge failures (050b was a judge failure), so the pass
attributes first and acts on the attribution.

**Who.** A fresh Codex container, the judge arm with `plan-prompt.md`. The container gets `base_sha` and `head` and
computes the diff itself; the host never runs `git diff` inside `$work` (a worker-written `.git/config` can name external
diff drivers). The note's text comes from `$gate`. Its inputs include the gate's verifier record when there is one.

**When.** Inside `cmd_run`'s finalisation, after the attempt's manifest is complete and before cleanup, while `$work`,
`$gate` and the run network exist. Triggered on the recorded outcome, never on the number: `outcome` in `blocked`,
`dependency_change`, `refuted` (which the REFUTED paths now set), with the worker and push steps exited 0, and only when
the batch asked with `FACTORY_REVISE=1`. **The step cannot touch the attempt's record**: `run_container` overwrites
`status` and has seven exits that do not return, so the planner runs in a subshell, any non-zero return or missing output
becomes `revision:{disposition:"unfixable", reason:"planner: …"}`, and `cmd_run` exits with the attempt's status whatever
happened. The planner's out dir joins cleanup's `rm` list.

**Output**, `/out/revision.json`, `attribution` first and one action:

- `spec` → `{"instructions": "...", "depends_on": [...]}`. The host assigns everything else: `repo` and `base_branch`
  from the original; `task_id` by the `requeue` rule (`<base id>-r<N>`, first retry `-r1`, scanning queue, `done/`,
  `failed/` and `held/`, refusing an existing destination; the eight lines move into a `next_id` helper). Host checks,
  all monotone or locked: the heading test; `CRED_RE`; the Goal and Done when **sections** identical (`Goal:` up to
  `\nContext:`, `Done when:` up to `\nOut of scope:`; first lines are not enough); `depends_on` ⊇ original; Out of scope
  lines ⊇ original (an explicit prohibition is the operator's authority, never a model's to remove); Scope may gain
  paths, none matching the refusal list (`(^|/)\.github/`, `workflows?/`, `(^|/)tests?/(helpers|setup|fixtures)`, every
  manifest and lockfile in `MANIFEST_RE` except `package.json` itself, and no catch-all like "all files"). Adding
  `package.json` under Scope is the one authority a revision may grant: it lifts the dependency-manifest gate for the
  rerun, it is the fix for `070` and `039b`, and it marks the task `scope_widened` (below). A Done when that is itself
  wrong is `unfixable`.
- `worker` → the same instructions, `-r1`, with one line under Context: "`origin/factory/<id>` holds a previous attempt
  that failed on: <the reproduced findings, bounded>." The old code is judged and gated again from scratch.
- `judge` → one fresh judge round on the same `head` with no claims in its prompt, then the gate. A pass ships; a fail
  stands, and the task is dead.
- `environment` → the infra retry from loop 2, no revision consumed.
- `wait_for: <task_id>` → a `spec` revision whose only change is `depends_on` (the failed attempt pushed
  `factory/<task_id>` and `cmd_run` refuses an existing branch). The target must be known, not the task's own base id,
  and not `is_dead`; a later queue task is allowed; a target already merged is `unfixable` (the worker was wrong). Cycle
  guard through the queue files' `depends_on`. `cmd_run` records `disposition:"proposed"`; the batch validates and decides.
- `unfixable: <reason>` → `failed/`, the reason in `.reason` so `notify` carries it, and the row.

**Once, ever.** A task whose id carries `-r<N>` never gets `FACTORY_REVISE=1`. A `-r1` that fails is dead; its dependents
wait for a human, and loop 3 says so. The audit trail is one paragraph the host appends after Out of scope: "Revised by
the planner (attribution <x>) from `<task_id>` (run `<run_id>`; the original is in queue/failed/)." The PR body is the
instructions, so it lands there; `scope_of` stops at `Done when:`, so the paragraph can widen nothing. The manifest keeps
`revision:{attribution, disposition, task_id|reason, scope_widened}`.

**Scheduling.** The batch's task loop is a `for` over a glob expanded once. It becomes a cursor loop: the cursor is the
**task id** of the last file taken, never the filename (`<id>-r1.json` sorts before `<id>.json` in C collation because `-`
precedes `.`; `<id>-r1` sorts after `<id>` as an id); each iteration lists the queue afresh and takes the first id after
the cursor, through the same top-of-loop checks (HALT, `--max-tasks`, `--stop-at`). `050b-web-auth.json` is moved out
before `050b-web-auth-r1.json` is written, and `-r1` comes next, before `051-…`. A waiting task is passed over once. A
revision or infra retry counts as a run (`--max-tasks` counts runs). A revision continues the batch whether or not
`--continue` was given, and the notification's last word comes from what the loop does next. Post-run order, so an
interruption never runs a file twice or loses a revision: move the original to `failed/`, write the queue file, then
`revision.queued:true`.

### 6. The morning readback: `factory status`

One read-only command, run by hand or by the batch at its start:

- for every task in `done/`: the PR's state (open, merged into `next`, promoted to `main`, closed, reverted) and CI
  conclusion, by head branch; `gate_pending` tasks and their resumption;
- rejection propagation: every merged or open PR whose `base_sha` descends from a reverted or closed head is flagged
  (the linear chain means each PR carries the commits below it);
- the queue: tasks whose dependencies are now merged, dead dependencies, held tasks with their reasons, stale
  `factory/*` branches;
- the invariant `main` ⊆ `next` (compare API: `behind` or `identical`), and the size of `next...main`;
- the measures, one line in `runs/status.tsv`.

It is the only place the factory and GitHub are reconciled.

### 7. The factory's own verification: a canary queue and a review replay

The orchestrator cannot be dogfooded through the factory (BSD `date` flags, `shasum` and `openssl` in the tests, a
Debian image with git, curl and ca-certificates, no CI check on the factory repo), and a container run would not exercise
the path where every misreported outcome so far has lived. The stubbed `test-factory.sh` never runs the entrypoint, so it
cannot prove the Claude arm's instruction suppression, the verifier's isolation or the ruleset.

- **Canary queue**: against a throwaway repo, run on the mini after every factory merge and before a real night: a task
  that passes the gate and auto-merges; one the loop judge passes and the gate must catch (a weakened test); one with an
  impossible Scope (note → triage → `-r1`, which stays a PR); one dependent on it (stays a PR: chain taint); one with an
  injected infra fault; one that changes a dependency manifest; one with a forced reproduced BLOCK fixed in one cycle
  (auto-merges). A script asserts each manifest's `outcome`, `class`, `exit_status`, `gate`, `revision` and the merge.
- **Negative tests of the ruleset with real tokens**, recorded in factory.md with the ruleset ids: a push to `next` with
  the push token is refused; a merge without `factory-gate` is refused; a merge with a stale `sha` returns 409; an App
  merge or approval on `main` is refused.
- **Replay**: `factory rejudge <run_id> [prompt-file] [--arm codex|claude|verify]` runs a reviewer or the verifier
  against an archived head. A corpus of merged PRs, the refuted runs and fault-injected variants turns every
  reviewer-prompt or model change into a measured one, scored by the verification measure. First use: the gate against
  the 15 open branches from last night, in shadow, before fix cycles are allowed to send work back. Replay needs the run
  dirs, so `runs/` retention is defined with it: never prune a run whose branch is unmerged or in the corpus.

## The merge gate

The reference architecture: approval weighs the verification a change has passed; automatic approval is an option;
approval comes from something other than the agent that made the change; a person remains accountable. Options:

| Option | Risk it accepts |
|---|---|
| (a) Today: approve each PR bottom-up | Throughput equals review time; cross-night dependents wait on it. |
| (b) Review the night as one PR: merge the top of the chained stack, close the rest | Shallower read per task; zero code. Still a human per night. |
| (c) Integration branch `next`, merged by the factory through a PR when the gate's check and CI are green; the human promotes `next` → `main` | Verified but not human-read code becomes the base for later nights; a gate miss, or a compromised mini, compounds until promotion, which is a size-capped review. No GitHub control can stop the host that holds the App key, so this is an accepted risk, stated in factory.md. |
| (d) Auto-merge to `main` | The mini can land anything on `main`. Rejected. |
| (e) Risk-tiered auto-merge | Path classification errors, for a small gain. |

**(c), reached only through a PR, never a push.** It is the only option under which the operator can leave for a week
and the line keeps moving across nights. The design, each line a control the reviews found missing:

- `next` has its own ruleset: a pull request required, 0 approvals; required checks `test` (pinned to Actions) and
  `factory-gate` (pinned to a **separate merger App**, checks:write and contents:write only, its key its own Keycard
  resource so its use is audited and revocable from a phone without stopping the push App); merge commits only; no
  force push; no App on the bypass list. `next` is **not** pushable by the push token (contents:write cannot be
  branch-scoped; if `next` were pushable, any push-token holder could push a merge commit with no gate). `main` keeps one
  human approval and the merge-commit method; `next` is carved out of the parity ruleset that restricts updates to
  `factory/**`. "Require branches up to date" stays off (with merge commits, B is never up to date after A's merge, and
  updating creates an ungated sha).
- In merge-gate mode every task's `base_branch` is `next` (lint enforces it per repo; the generator emits it): the PR
  targets `next`, the conflict gate tests against `next`, the first task of a night is cut from `next`. The target repo's
  CI runs `pull_request` for base `next`, and no secret-bearing workflow triggers on `push` to `next` (a step in "Prepare a
  target repo").
- The host posts `factory-gate` on the gated `head_sha` with the verifier record's sha256 in its description, then
  merges `PUT /pulls/{n}/merge` with `sha=<head>` (409 if the head moved), with the merger App's token minted for that
  step only and never present in any container. A lost merge response is reconciled by `GET` before it is called a
  failure (outcome rule 3); the merge sha and state are persisted separately from `pr_url`. CI is asynchronous: the host
  waits for the required checks on that sha, bounded, and a timeout leaves the PR open for `factory status`.
- **Chain taint**: the merge happens only when the run's chain base (`base_sha`) is already an ancestor of `next`'s tip
  (compare API, or `merge-base --is-ancestor` in `$gate`). Otherwise the PR carries an ancestor that was held for a
  human, and auto-merging it would land that ancestor unseen; both the Codex and the Claude review found this. Anything
  held back therefore holds back everything chained above it: those open PRs.
- **Held for a human**: a task marked `scope_widened` (a revision added `package.json`; the human seeing the full Scope is
  the last check on what the planner widened). A change whose gate had a reproduced BLOCK that was then fixed
  **auto-merges**: the final gate on the final head is the same evidence that merges an untouched change, and the cycle
  history goes in the merge-commit body and the verification measure; holding it would mean the better the gate, the
  more PRs the human reads.
- **Accumulation cap**: past `N` merges or `L` changed lines in `next...main`, the factory opens PRs instead of merging,
  so the promotion review stays readable; `factory status` reports the size. The promotion is a PR whose body lists each
  merged factory PR with its gate record and Scope, `scope_widened` first, merged with a merge commit; the operator then
  fast-forwards `next` to it and forward-merges any hotfix. The batch checks `main` ⊆ `next` at start and stops with a
  notification otherwise.
- **Revert procedure**: revert A, then every `next` merge whose `base_sha` descends from A's head (B was cut from A, so
  reverting A alone leaves B's code without A); the revert title is the dependency check's signal (loop 3), and `factory
  status` lists the descendants to revert. Reverts are not cheap in a chain; the procedure makes them correct.
- **Kill switch** from a phone: set `next`'s ruleset to require one approval, or suspend the merger App. `factory stop`
  needs a shell on the mini.
- A merge-API failure after a clean gate opens the PR instead: exit 0 if the PR opened, `done/`, `prev` advances.

(b) is the fallback for a repo that cannot have a `next` ruleset, and the mode until the canary and the negative ruleset
tests pass.

## Tests (`test-factory.sh`, stubbed modes), landing with each loop

Loop 0: a gate with no reproduced BLOCK opens the PR with both reviews and the verifier record; a BLOCK that fails at
head and base with no clause is a NOTE; a regression blocks; a missing review file is `gate_error`, never a pass; a
reproduced BLOCK costs one worker round, one judge round and a re-gate; no new commits in a cycle is refuted; the same
repro reproducing twice is dead; `judge.rounds` counts the cycle's round; the gate runs after the cheap gates and the
push. Loop 1: deep lint adds `depends_on` in place under the same id with provenance; a removal is refused; a
contradiction is held with reason and proposal; an all-held queue reports held, not success; a failed deep lint proceeds
with a notification. Loop 2: a push that failed records `pushed:false` and `final_sha` null and stays in the queue; a
pushed exit 6 is `-i1`; an exit 11 retry is cut from the conflicting branch; a retry with the same outcome is a task
failure; two infra exits from distinct tasks stop the batch with the queue intact and one notification; exit 4 on a clean
gate goes to `done/` and chains. Loop 3: waits; lint on failed, held, later, cycle; `-r1` and `-i1` satisfy; a reverted
dependency is dead; the declared-base skip matches `factory/A-i1`. Loop 4: a note after round 1 skips the judge (`bk`
fixture updated); a note on top of code is blocked, a deleted note is not. Loop 5: `spec` → `-r1` next with the original's
repo and base; a changed Goal or Done when, a removed Out of scope line, a dropped `depends_on`, or `.github/` in Scope is
unfixable; `package.json` added marks `scope_widened`; `judge` runs one claim-free round then the gate; `worker` adds the
branch pointer; `wait_for` later becomes `-r1`, `wait_for` dead is unfixable; a `-r1` is never revised; a planner `die`
leaves the attempt intact; the cursor loop takes `<id>-r1` after `<id>` (C collation case); a batch killed between run
and requeue runs nothing twice; a recovered chain exits 0; a killed worker still exits 137. Merge gate: a gated pass with
its chain base in `next` merges in the stub; `scope_widened` and a task chained above a held one open PRs; a lost merge
response is reconciled. The misreported-outcome rule in factory.md applies to all of it.

## What last night would have looked like

| Task | Last night | With this plan |
|---|---|---|
| 050b web auth | judge wrong for 3 rounds, worker reverted, blocked | deep lint holds it (Scope vs Goal) with a proposed fix before the night; failing that, the fact-separated judge rule tests the claim in round 1; failing that, triage attributes `judge` and a fresh judge plus the gate ship the implementation |
| 070 workshop-ui | refuted x5 | deep lint holds it (Done when needs deps Out of scope forbids) with the proposal; or round 2's note → triage `spec` with `package.json`, `scope_widened`, PR for the human |
| 039b, 083, 039a | refuted / blocked | held with proposals, or one `spec` revision each, same night |
| 035 restore-and-solve | killed in round 4 | `class:"infra"` (137), one `-i1` retry |
| 18 blocked | one worker round plus one judge round each | most held by deep lint; the rest one worker round each |
| 15 dependents | 5 rounds each, `failed/` | wait on their root; run the same night once it passes |
| 15 PRs | opened, awaiting 15 human reviews bottom-up | gated by a Claude break-it review, a Codex integrity review and a mechanical verifier; those with a clean gate and a clean chain merge into `next`; `scope_widened` ones and what is chained above them open PRs; one promotion review when the operator returns |

## Dropped in review

- **A nightly spend ceiling.** The operator's call. Thrash is bounded by rounds, gate cycles on no-progress and the
  one-revision rule.
- **Deferring the ship-side gate until measured.** This session's own review is the measurement.
- **Parallel gate steps.** `run_container` is not parallel-safe and the verifier depends on the reviews.
- **Text BLOCK lines; an exact expected exit code; "fails at head" as evidence.** JSON findings, `nonzero`, and
  regression-or-unmet against base.
- **A Codex integrity lens that blocks.** It cannot produce a repro; its mechanically checkable parts are host gates and
  verifier checks.
- **Deep lint widening Scope or removing anything; lint revisions as `-r1`.** Additions and holds only, in place.
- **`next` pushable by the App; "a token scoped to `next`".** Contents:write cannot be branch-scoped; `next` is reached by
  PR with a pinned check from a separate App.
- **Holding every once-BLOCKed change for a human.** The final gate is the evidence; the cycle history is recorded.
- **"Context-free" as the name for the round judge.** It is a fresh session with prior claims marked untrusted and
  orchestrator facts separated; the gate is the context-free review.
- **A stall stop on all-`REPEAT` rounds; `FACTORY_MAX_REVISIONS`; `revised_from`; a diff in the PR body; the ancestor
  test alone as merged truth; dogfooding through the factory; a merged check from local manifests.** As before.
- **Still dropped:** splitting a task in revision; inferring dependencies from task text alone; a parallel chain per
  dependency subtree.

## Task-file fixes from the 2026-11-01 handoff, not factory code

Two patches exist (`tasks: unblock the web and workshop-ui chains` in the workshop repo; `judge: test a claim before
writing it`, landed as 31edc5f). Of the handoff's task-file items: the web tasks' tsconfig problem is one line in the
scaffold (`include: ["**/*.ts", "**/*.tsx"]` in `apps/web/tsconfig.json`, on the unmerged PR 63) rather than a Scope
suffix on every web task; 070, 039a, 039b (with 038b), 019c, 056b and 071a/b name their dependencies as the patch does;
055a to 055c move after 059b (lint now refuses the old order); `docs/image-pins.md` is filled before 083 is queued. Before
the next night: the mini pulls, the image is rebuilt if the Dockerfile changed, the `kwp` clone is refreshed, and the queue
is loaded from `factory-tasks/`, never from `queue/failed/`.

## Within two weeks, not in this plan

Branch litter (`factory status` lists stale `factory/*` branches). Model pins retired: loop 2 classifies it as infra.
macOS, Docker Desktop and OrbStack updates on the mini. Review fatigue at promotion; the accumulation cap and the
escaped-defect measure are the guard. A daily heartbeat notification even with nothing run. Parallel subtrees once the
DAG exists.

## Order

0. The task generator emits `depends_on` and `base_branch: next`; the target repo creates `next` with its ruleset, the
   separate merger App is installed with its Keycard resource, the parity ruleset carves out `next`, factory PRs use merge
   commits, and no secret-bearing workflow triggers on `push` to `next` (parity thread for the rulesets).
1. Loop 2 (classification, `pushed`, infra retry, circuit breaker), with tests.
2. Loop 3 (dependencies, GitHub merged-and-unreverted check, `is_dead`, dead dependencies escalated).
3. Shared machinery: `next_id`, `held/`, `unhold`, the monotone revision checks, the cursor loop on ids, `touches.tsv`.
4. Loop 4 (worker sentence, note-at-head judge skip, gate rewrite and order) and the fact-separated judge prompt.
5. Loop 0 (the `review` and `verify` arms, image rebuild, the gate after the push, cycles, `gate_pending`), opening PRs
   only: option (b) for the human while it runs.
6. Loop 7's canary and the negative ruleset tests. Then enable the merge into `next` with chain taint, `scope_widened`
   and the accumulation cap. **From here the operator can leave for a night.**
7. Loop 1 (deep lint, additions and holds) and loop 6 (`factory status`, the invariant, the revert procedure).
8. Loop 5 (triage with attribution, revision file, host requeue, report and exit rule). **From here the operator can
   leave for a week.**
9. Loop 7's replay against last night's 15 branches, then fix cycles are allowed to send work back.

Each is its own PR, reviewed before landing the way this plan was: one anchored reviewer, then fresh lens reviewers, then
every finding verified against the code.
