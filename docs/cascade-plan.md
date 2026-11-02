# Cascade plan: the loops a factory needs to keep moving without a human

Goal: a failure is repaired by the line or routed around, never left to stall the queue; the human is the outermost loop
and is reached asynchronously, with the line still moving on everything that does not need them.

Evidence (batch of 2026-11-01, keycard-workshop-platform): 40 tasks, 12 hours. 15 PRs, 18 blocked, 6 refuted, 1 killed.
Two roots did most of the damage. `050b web auth` was refuted for three rounds on a judge claim the judge had not tested
(a tsconfig entry "unnecessary"; TS6307 when it finally tried it in round 4), by which time the worker had reverted a
working implementation and written a BLOCKED note (commit 31edc5f). Then 051 to 057, 081 and 082 each ran up to five rounds
and failed because no signed-in participant exists on the branch: ten tasks, about five hours. `070 workshop-ui` was
refuted five times for the same forbidden dependencies, then 071a to 072d failed on the missing predecessor. `039b`: a
dependency the task forbade. `083`, `039a`: spec gaps. In every case the failure was known the moment the root ended,
nothing acted on it, and the fix (PRs 53 and 54) was a human editing specs the next day. About five of the twelve hours
went to tasks that could not succeed.

What the night shows is not one bug but a missing shape. The factory has one loop (worker ↔ judge on the code) and
nothing around it: no notion that a failure can be the environment's rather than the task's, no notion that one task
needs another, no repair when the code loop cannot converge, and no readback of what happened to last night's PRs. The
plan adds those, in the order they pay.

The ladder, stated once: code loop → attribution (spec, worker, judge, environment) → one of {revise the spec, a fresh
worker pointed at the old branch, a fresh judge, an infra retry} → human. Each rung has a budget; exhaustion escalates one
rung up; the human's fix re-enters the queue as a spec PR. Sideways: a circuit breaker that stops the line, queue intact,
when the failures are systemic. Stopping on a systemic fault is part of non-blocking, not the opposite of it.

Reviewed 2026-11-02 by Codex (15 findings), four lens reviewers (mechanics, security, termination and reporting,
over-engineering) and Opus 5.5 with fresh context (14 findings, which set this order). What held is folded in; the notes at
the end list what was dropped and why.

## Measures

The factory is not measured by touches avoided (the ruleset guarantees one human approval per PR, so that number is
unreachable by design and the cheapest way to raise it is to loosen a gate). Four numbers per night, recorded by `factory
status` (loop 5):

- merged PRs per human review-hour;
- unplanned touches: hand requeues, hand spec edits, hand queue rebuilds (the merge review is planned);
- escaped defects: PRs the human rejected, CI red after the PR, reverts;
- dead compute: worker and judge rounds spent on tasks that ended dead.

The third is the counterweight that makes the other three safe to optimise.

## Loops

### 1. Task or infra: classify every outcome, retry infra, break the circuit

Today `cmd_batch` moves every non-zero exit to `failed/`, whatever the cause. A token-exchange `die` (exit 1 before any
worker round), a judge that produced no verdict because npm was down (6), a PR open that failed (4), a gate that could not
fetch (12), a stop or watchdog kill (137), a model pin retired, the Anthropic workspace limit reached at 2 a.m.: all look
like the task's death. Under `--continue` an outage moves every remaining task to `failed/`; with dependencies (loop 2)
each one parks a subtree; and a hand `requeue` the next morning spends the task's one revision (loop 4) on a failure that
was never its own.

- Every exit gets a class in the manifest, `class:"task"|"infra"`, set where the outcome is set: task = 3, 5, 10, 13, 14;
  infra = 1 (before the first worker round), 4, 6, 11 on a passing verdict, 12, 130, 137. A worker container's own exit
  code passes through as the run's status, so the class is decided from `outcome` and the round state, never from the
  number alone.
- Infra with nothing pushed (`final_sha` null): the task stays in the queue under its own id; nothing exists on GitHub,
  so the id is reusable. Infra with a pushed branch: one same-night retry as `<id>-i1` from the same chain base, outside
  the revision rule, with `retry_of` in the manifest. Exit 4 on a passing verdict counts as passed for chaining (the branch
  is pushed and judged; only the PR is missing, and `factory status` opens or reports it).
- Circuit breaker: two consecutive infra failures stop the batch with everything left in the queue untouched and one
  notification naming both. One operator, one mini; a third attempt at 3 a.m. is a third identical failure.
- The failure notification carries the class: `050b exited 6 (infra: no verdict, retrying as 050b-i1)`.

### 2. Declared dependencies that wait, with GitHub as the truth for "merged"

An optional field `"depends_on": ["050b-web-auth"]`. `JOB_SCHEMA` gets a second clause (its `all(.[]; type=="string")`
rejects an array), in the one definition `run`, `lint` and `requeue` share. The task generator in the workshop repo emits
it: it knows the decomposition, and reconstructing the graph afterwards by LLM is lossy. `cmd_lint` prints the graph,
normalises ids to base ids (the `-r<N>` / `-i<N>` suffix stripped once), and refuses cycles and unknown ids; a dependency
on a later task or a failed one is a wait, not an error, so one dead root cannot stop an unrelated queue from starting.

Before a task runs, every dependency must be available on the branch the task is cut from:

- passed tonight in chain mode (`passed` set of base ids; the linear chain contains every passed task), or
- merged, as GitHub says: `GET /repos/<r>/pulls?state=all&head=<owner>:factory/<id>` for the base id and its revisions,
  and `merged_at` set on one of them. Not the local run record: `runs/` has no retention policy and a pruned manifest must
  not become a task that waits forever. Not an ancestor test: the target repo allows squash and rebase merges, after which
  the pushed sha is never reachable from `main`. The mint is `open_pr`'s (pull_requests + contents:read), lazy, once per
  repo, only when a `depends_on` check needs it, so a queue without dependencies and every `test-factory.sh` batch mint
  nothing. The owner/name normalisation and the App-vs-file token split move out of `cmd_run` into a helper; the batch
  clears `rundir` before minting (`mint_github_token` writes `installation_id` into `$rundir/manifest.json` when set). The
  file-token dry run keeps the ancestor test. Under `--no-chain` only merged counts, and a dependency's repo must equal the
  dependent's (lint).

Otherwise the task waits: row `waiting on <id>`, file untouched, visited once per night (the cursor loop in loop 4), so a
dependency that passes later the same night releases it the next night. **A wait on something dead is not a wait.** Dead:
the dependency's PR was closed unmerged, it is in `failed/` with no queued revision, or its `-r1` failed. That is a row of
its own, `waiting on <id> (dead: closed PR)`, it counts as dead for the batch's exit status, and it is notified. A wait older
than one night is notified too. A night where all 40 tasks wait on one dead root must not exit 0 with a cheerful summary.

Unchanged: the `--continue` skip for a declared `base_branch: factory/<id>` (it names an exact branch, and a revision has
another name). Last night this loop alone saves ten web tasks and five UI tasks, about seven hours.

### 3. The worker's BLOCKED note ends the run before the judge

The worker prompt already demands `docs/BLOCKED-<task_id>.md` for a missing prerequisite, and since 31edc5f the judge
prompt reports a check that passes only with an out-of-scope change as blocked in the round it is found. One sentence
extends the worker's rule to a reviewer finding: when a finding can only be satisfied by leaving Scope, adding a dependency
the task forbids, or a prerequisite that is not on the branch, do not attempt it; write the note (first text line the
reason, then what is missing and which task or Scope change would supply it, in prose; the host does not parse it, the
planner reads it) and stop.

Three orchestrator edits, each a few lines:

- Note at head ends the round loop before the judge: after the round's `head` is resolved and the idle check,
  `git -C "$work" cat-file -e "$head:docs/BLOCKED-$task_id.md"` (rev-parse already runs there without a token) breaks with
  `judged` unchanged. A round-1 note gives `judge:{rounds:0, verdict:null}` and exit 10, which `report` and `requeue`
  already handle. Today a round-1 note costs a judge round that refutes it and a worker round that commits nothing: 18
  tasks last night. The `bk` fixture in `test-factory.sh` (verdicts `REFUTED,VERIFIED`, asserting REFUTED on the blocked
  task) becomes `VERIFIED` with rounds 0 and verdict null.
- Blocked gate: this task's note exists at `$head`, `git -C "$gate" cat-file -e` (a missing path exits 128; test with
  `if … 2>/dev/null`), replacing the `files | grep -v '^docs/BLOCKED-'` test. A note on top of code in round 3 is blocked; a
  deleted note or another task's note is not. Consequence: a VERIFIED branch that also carries this task's note is exit 10
  with no PR, where today it ships; that matches the worker prompt.
- The dependency-manifest gate moves ahead of the blocked gate, so a note beside a manifest change is `dependency_change`,
  not a block that hides it. The `gt` (fetch or diff failed) branch stays first; both gates need the diff.

### 4. One fresh triage pass on a dead task: attribute, then act once

A task is dead when the code loop ends refuted, blocked or on a dependency change. Today nothing happens. A spec rewriter
applied to every death would bend specs around worker and judge failures (050b was a judge failure), so the pass attributes
first and acts on the attribution.

**Who.** The judge container with `plan-prompt.md` instead of the judge prompt. The judge entrypoint already does what
this step needs: a fresh clone of `/src` at `HEAD_SHA`, the agent config files stripped, Codex with `--ignore-user-config
--ignore-rules`, read-only input, output to a separate `/out` mount accepted only when the container exited 0 and the file
is a regular non-symlink under 200000 bytes. A Claude arm would need the same stripping plus project settings and hooks
disabled, and an image rebuild; the judge arm has it today. Codex and the judge share a model, so their errors are
correlated; that is accepted for now and is why the attribution `judge` re-judges with no ledger rather than asking the
same context again. The log line names the step `plan`. The container gets `base_sha` and `head` and computes the diff
itself; the host never runs `git diff` inside `$work` (a worker-written `.git/config` can name external diff drivers). The
note's text comes from `$gate`, where the blocked gate already reads it.

**When.** Inside `cmd_run`'s finalisation, after the attempt's manifest is complete (`ended_at`, `exit_status`,
`final_sha`, `judge`) and before cleanup, while `$work`, `$gate` and the run network exist. Triggered on the recorded
outcome, never on the number: `outcome` in `blocked`, `dependency_change`, or `refuted` (which the REFUTED path now sets, so
the three are one test), with the worker and push steps exited 0, and only when the batch asked with `FACTORY_REVISE=1`.
**The step cannot touch the attempt's record**: `run_container` overwrites `status` and has seven exits that do not return
(HALT, proxy start and listen, egress record, `exit 12` on a log-pipeline failure), so the planner runs in a subshell, any
non-zero return or missing output becomes `revision:{disposition:"unfixable", reason:"planner: …"}`, and `cmd_run` exits
with the attempt's status whatever happened. The planner's out dir joins cleanup's `rm` list; cleanup's "only when
`ended_at` is null" guard then protects the record on every path.

**Output**, `/out/revision.json`, with `attribution` first and one action:

- `spec` → `{"instructions": "...", "depends_on": [...]}`. The host assigns everything else: `repo` and `base_branch`
  from the original; `task_id` by the `requeue` rule (`<base id>-r<N>`, first retry `-r1`, scanning queue, `done/` and
  `failed/`, refusing an existing destination; the eight lines move into a `next_id` helper with two callers). Host
  checks: the heading test, `CRED_RE`, the Goal and Done when **sections** identical to the original's (`Goal:` up to
  `\nContext:`, `Done when:` up to `\nOut of scope:`; lint's regex accepts a second `Goal:` line further down, so first
  lines are not enough), and Scope text the revision adds must not name CI, workflow, test-helper, fixture or lockfile
  paths (`(^|/)\.github/`, `workflows?/`, `(^|/)tests?/(helpers|setup|fixtures)`, `package-lock.json`): the judge treats
  anything Scope names as in scope, and a `factory/*` branch's workflows run with the repo's secrets. Every spec root last
  night needed only Context, Scope, Out of scope or `depends_on` to change; a Done when that is itself wrong is a human's.
- `worker` → the same instructions, `-r1`, with one line added under Context by the host: "`origin/factory/<id>` holds a
  previous attempt that failed on: <the final findings, bounded>." The worker's clone already has that ref; the old code is
  judged again from scratch, so reuse costs no trust.
- `judge` → one fresh judge round on the same `head` with no previous findings in its prompt. VERIFIED or CAVEATS there
  ships the branch with both reviews in the PR body; REFUTED stands, and the task is dead.
- `environment` → the infra retry from loop 1, no revision consumed.
- `wait_for: <task_id>` → a `spec` revision whose only change is `depends_on` (the failed attempt pushed
  `factory/<task_id>` and `cmd_run` refuses an existing branch, so the same id cannot run again). The target must be known
  and not the task's own base id; a later queue task is the useful case and allowed; a target in `failed/`, dead tonight,
  or already merged is `unfixable` (a worker that cannot do the task must not park it, with exit 0, on a root nobody will
  requeue). Cycle guard through the queue files' `depends_on`. These checks need the queue directory, which `cmd_run` does
  not have, so `cmd_run` records `disposition:"proposed"` and the batch validates and decides.
- `unfixable: <reason>` → `failed/`, the reason in `.reason` so `notify` carries it, and the row.

Anything else is `unfixable: planner output invalid`.

**Once, ever.** No cap, no counter: a task whose id carries a `-r<N>` suffix never gets `FACTORY_REVISE=1`. That is
`cmd_requeue`'s rule ("a task that fails the same way twice is not run a third time on its own"), it is bounded across
nights, and every root last night needed exactly one. A `-r1` that fails is dead; its dependents wait for a human (loop
2 notifies). The audit trail is one paragraph the host appends after Out of scope: "Revised by the planner (attribution
<x>) from `<task_id>` (run `<run_id>`; the original is in queue/failed/)." The PR body is the instructions, so it lands
there; `scope_of` stops at `Done when:`, so the paragraph can widen nothing. Naming `package.json` under Scope is the
entire dependency-manifest authorization, so a `spec` revision that adds it lifts that gate for the rerun: deliberate, it
is the fix for `070` and `039b`, and the human sees the whole Scope on the PR. The manifest keeps
`revision:{attribution, disposition, task_id|reason}`.

**Scheduling.** The batch's task loop is a `for` over a glob expanded once, so a file written mid-loop is never seen. It
becomes a cursor loop: the cursor is the name of the last file taken; each iteration lists the queue afresh (C collation,
as the glob) and takes the first file after the cursor, through the same top-of-loop checks (HALT, `--max-tasks`,
`--stop-at`). A revision needs no special case: `050b-web-auth.json` is moved out before `050b-web-auth-r1.json` is
written, and `-r1` sorts after the cursor and before `051-…`. A waiting task is passed over once, so the loop ends. A
revision or infra retry counts as a run (`n`). A revision continues the batch whether or not `--continue` was given, and
the per-task notification's last word comes from what the loop does next (`revising -> 050b-web-auth-r1`, `continuing`,
`stopped`), not from the flag. Post-run order, so an interruption (a trapped signal is delivered after the child returns,
so exactly here) never runs a file twice or loses a revision: move the original to `failed/`, write the queue file, then
`revision.queued:true` in the manifest.

### 5. The morning readback: `factory status`

The factory never learns what happened to its PRs. `done/` means "a PR was opened"; the queue the morning after is
rebuilt by hand from memory notes. One read-only command, run by hand or by the batch at its start:

- for every task in `done/`: the PR's state (open, merged, closed) and CI conclusion from GitHub, by head branch;
- rejection propagation: every open PR whose chain base ancestry includes a closed PR is flagged (the linear chain means
  each PR carries the commits below it; a rejected PR k is inside every PR above it);
- the queue rebuild: tasks whose dependencies are now merged are reported as runnable; dead dependencies as in loop 2;
- the four measures, appended to a `runs/status.tsv` one line per morning.

This is where loop 2's merged check lives, and it is the only place the factory and GitHub are reconciled.

### 6. The factory's own verification: a canary queue and a judge replay

The orchestrator cannot be dogfooded through the factory: it uses BSD `date` flags, `test-factory.sh` uses `shasum` and
`openssl`, the Debian image has git, curl and ca-certificates, and the factory repo has no CI check. And a container run
would not exercise the path where every misreported outcome so far has lived: the mini with real Docker, proxies, Keycard,
Codex and GitHub.

- **Canary queue**: five tasks against a throwaway repo, run on the mini after every factory merge and before a real
  night, with a small budget and `--max-tasks`: one that passes; one with a deliberately impossible Scope (note → planner →
  `-r1`); one dependent on it; one with an injected infra fault (a bad `FACTORY_NOTIFY_URL`, a revoked key); one that
  changes a dependency manifest. A script asserts each manifest's `outcome`, `class`, `exit_status` and `revision`.
- **Judge replay**: `factory rejudge <run_id> [prompt-file]` runs the judge arm against an archived head with a given
  prompt. A corpus of merged PRs, the refuted runs, and fault-injected variants turns every judge-prompt change (today
  driven by one incident at a time: 011, 050b) into a measured one. First use: replay the current prompt against the 15
  open branches from last night, in shadow, and verify what it finds, before deciding whether a VERIFIED-side gate is worth
  anything.

### 7. A nightly spend ceiling

Worst case per root under loops 1 to 4: five worker and five judge rounds, a plan step, then five and five again on
`-r1`; about eleven worker rounds at up to `$10` each plus a dozen Codex runs the factory cannot see the price of.
`--max-tasks` counts runs, not dollars. Between tasks the batch sums `worker.rounds[].reported_cost_usd` across tonight's
manifests plus a judge-run count (one `jq` over files that exist) and stops at `FACTORY_NIGHT_BUDGET_USD`, queue intact,
with a notification.

## The merge gate

The ruleset requires one human approval per PR, so the human is the merge. The options for one operator:

| Option | Risk it accepts |
|---|---|
| (a) Today: approve each PR bottom-up | Throughput equals review time; cross-night dependents wait on it. |
| (b) Review the night as one PR: merge the top of the chained stack (it contains every passed task), close the rest | One larger diff per review, so a shallower read; a bad task in the middle means cutting the stack there and requeueing what was above it. Zero code. |
| (c) Integration branch `next`, auto-merged VERIFIED + CI, human promotes `next` → `main` | Unreviewed code becomes the base for later nights, so errors compound before a human sees them; the mini, an untrusted host in this design, gains merge rights. |
| (d) Auto-merge VERIFIED + CI to `main`, App in the bypass list | The mini can land anything on `main`; CI runs scripts the worker can edit; a planner-widened Scope ships unseen. Contradicts the trust model. Rejected. |
| (e) Risk-tiered auto-merge (docs- or tests-only diffs) | Path classification errors, for a small gain. |

**(b) now.** The gate on `main` is unchanged, and the "fifteen stacked PRs" ceiling becomes one review a day. Use merge
commits on factory PRs: a squash leaves the stack's commits unreachable, so the next PR's diff does not shrink and can
conflict. Revisit (c) only once `factory status` shows a run of nights with zero escaped defects. Under any auto-merge,
ever, exclude revised (`-rN`) tasks: the human seeing the full Scope on the PR is the only check on what the planner widened.

## Tests (`test-factory.sh`, stubbed modes), landing with each loop

Loop 1: an exit 6 stays in the queue under its own id with `class:"infra"`; a pushed-then-exit-4 is `-i1` and chains;
two infra exits stop the batch with the queue intact and one notification. Loop 2: a task whose dependency failed tonight
waits and the row says so; a dependency in `failed/` or later in the queue passes lint; a cycle fails lint; a passing
`-r1` satisfies a dependency on the base id; a `done/` dependency with an unmerged PR waits (file path: ancestor test); a
wait on a dead dependency counts as dead for the exit and is notified. Loop 3: a note after round 1 skips the judge (`bk`
fixture updated); a note on top of code is blocked, a deleted note is not. Loop 4: a plan stub returning `spec` gets `-r1`
queued next and run with the original's repo and base; a stub changing `Goal:` or `Done when:`, or adding `.github/` to
Scope, is unfixable; `judge` runs one ledger-free round and ships on VERIFIED; `worker` adds the branch pointer; `wait_for`
a later task becomes `-r1` with `depends_on`, `wait_for` a dead task is unfixable; a `-r1` is never revised; a planner
`die` leaves the attempt's exit status and outcome intact; a batch killed between run and requeue runs nothing twice next
night; a recovered chain exits 0; a killed worker still exits 137. Loop 7: the batch stops at the ceiling with the queue
intact. The misreported-outcome rule in factory.md applies to all of it.

## What last night would have looked like

| Task | Last night | With this plan |
|---|---|---|
| 050b web auth | judge wrong for 3 rounds, worker reverted, blocked | 31edc5f's judge rule tests the claim in round 1; failing that, triage attributes `judge`, a ledger-free rejudge ships the reverted-to implementation |
| 070 workshop-ui | refuted x5 | round 2's worker writes the note, no judge; triage attributes `spec`, allows the named deps (`-r1`); 071a to 072d wait, then run |
| 039b, 083, 039a | refuted / blocked | one `spec` revision each, same night |
| 035 restore-and-solve | killed in round 4 | `class:"infra"` (137), one `-i1` retry, no revision consumed |
| 18 blocked | one worker round plus one judge round each | one worker round each |
| 15 dependents | 5 rounds each, `failed/` | never ran until their root passed; still in the queue, reported as waiting, if it did not |
| the morning | queue rebuilt by hand from notes, 15 PRs reviewed one by one | `factory status` rebuilds it; one stacked review |

## Dropped in review

- **A stall stop on all-`REPEAT` judge rounds.** Vacuous in round 2, would stop a loop that fixed four of five findings,
  fires on CAVEATS. Loop 3 covers 070; the `judge` attribution covers the anchoring case; `MAX_ROUNDS` bounds the rest.
- **A Claude `plan` entrypoint.** It would run the worker's committed hooks and `CLAUDE.md`; the judge arm strips them.
- **`FACTORY_MAX_REVISIONS`.** Config for a value that never changes; once is the house rule.
- **`revised_from` and a diff in the PR body.** The original is in `failed/` with its run dir; the PR shows the full
  current instructions; a provenance paragraph costs one line.
- **The ancestor test and the local manifest as the merged check.** Squash merges defeat the first; `runs/` retention
  must not decide queue semantics.
- **A VERIFIED-side fresh-eyes gate.** The inference from today's reviews (Codex 15, four lens reviewers ~30 more) is
  confounded: a different model, four times the effort, a bigger document, findings counted not validated. The recorded
  judge error is a false REFUTED, so the fresh pass goes on the death path (loop 4). Measure the VERIFIED side with loop
  6's replay first; if a gate is ever added it is downgrade-only, blocking only on a reproduced failing gating check, a
  weakened test or a scope violation.
- **`lint --deep` by LLM, and dogfooding the orchestrator through the factory.** The generator emits `depends_on`; a
  laptop review of `factory-tasks/` before copying is zero factory code; the orchestrator cannot run in the image and a
  container run would not prove the mini path (loop 6 does).
- **Still dropped:** splitting a task in revision; a parallel chain per dependency subtree (the DAG from loop 2 makes it
  possible later; correctness first); inferring dependencies from task text.

## Within two weeks, not in this plan

Branch litter (every failed attempt pushes `factory/<id>`, and the push token reaches any unprotected branch; `factory
status` should list stale ones). Model pins retired (`claude-opus-5-5`, `gpt-6.1-sol`): loop 1 classifies it as infra so it
does not kill 40 tasks one by one. macOS, Docker Desktop and OrbStack updates on the mini. `runs/` retention. Review
fatigue, which shows up as rubber-stamping before it shows in a number; (b) plus the escaped-defect measure is the guard.
A hand-written `depends_on` on a `-r1` id; lint normalises.

## Order

0. The task generator emits `depends_on`; `factory-tasks/` in the workshop repo gets it on the web and UI tasks. No
   factory code; it is what loop 2 is for. Switch the target repo's factory PRs to merge commits.
1. Loop 1 (classification, infra retry, circuit breaker), with tests.
2. Loop 2 (dependencies, GitHub merged check, dead dependencies escalated) and loop 7 (ceiling), with tests.
3. Loop 3 alone (worker sentence, note-at-head judge skip, gate rewrite and order). Then one real night under (b), so the
   plan prompt is written against the notes, judge files and `status` output that 1 to 3 produce.
4. Loop 5 (`factory status`), since the night's readback is needed before the next.
5. Loop 4 (plan prompt, attribution, revision file, host requeue, cursor loop, report and exit rule).
6. Loop 6 (canary queue, `rejudge`), then the replay of the 15 branches.

Each is its own PR, reviewed by Codex on the misreported-outcome class before it lands. No image rebuild is needed.
