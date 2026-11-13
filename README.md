# software-factory

The software factory turns a task file into a reviewed pull request. You write a task, and the factory runs Claude Code in a locked-down container against a fresh clone of the target repo. Codex reviews the result in a second container and tries to refute it. If the work survives review, the factory opens a pull request for a human to approve. The factory never merges.

It is a Level 2 (workflow-orchestrated) factory in the terms of the [Agent Baseline Secure Software Factory reference architecture](https://agentbaseline.org/reference-architecture). [Security model](#security-model) lists where it meets that architecture and where it doesn't yet.

## How it works

![The factory's run loop: a task file goes to the orchestrator, which gets credentials from Keycard and runs the worker, judge and push containers, then opens a pull request for human review](docs/flow.svg)

One run takes one task through these steps:

1. The orchestrator (`factory`, a bash script on the Mac mini) checks the task file, takes the one-job lock, and writes `runs/<run_id>/manifest.json` before it issues any credential.
2. It gets the GitHub App private key from Keycard Vault, mints a one-hour installation token scoped to the target repo, and clones the repo.
3. It gets a one-hour Anthropic token (Keycard issues a signed token, and Anthropic Workload Identity Federation exchanges it) and starts the worker container. Claude Code reads `worker-prompt.md` and the task, then commits on `factory/<task_id>`. Before it writes code, it checks that every table, file, export and dependency the task relies on exists on the branch. If one is missing and the task doesn't add it, the worker commits `docs/BLOCKED-<task_id>.md` naming what's missing and stops. If the first round makes no commits, the run ends with exit 3.
4. The orchestrator gets the Codex key from Keycard Vault and starts the judge container on a read-only copy of the worker's tree. Codex follows `judge-prompt.md`: it reads the diff, runs the repo's checks, looks for bugs, scope creep, weakened tests and over-engineering. It then lists each "Done when" clause as `DONE` (with the test or command that proves it) or `MISSING`, and ends with one verdict. Any `MISSING` clause rules out VERIFIED and CAVEATS.
5. CAVEATS and REFUTED go back to the worker with the judge's findings, for up to five rounds in total (set `FACTORY_MAX_ROUNDS` to change it). VERIFIED or no verdict ends the loop. A revision round that adds no commits also ends it, and the previous verdict stands.
6. A push container pushes the last judged commit with a fresh `contents:write` token, whatever the verdict, so you have the evidence. If a revision round's worker fails, the run pushes the last judged commit, opens no PR, and exits with the worker's status. A first round that fails leaves nothing to push.
7. The orchestrator fetches the pushed branch and the current target branch into a fresh bare repo on the host. If the task's `docs/BLOCKED-<task_id>.md` note is at the pushed head, the run ends with exit 10 and no PR, whatever the verdict (a note written in round 1 was never judged: the worker's note ends the run before the judge).
8. On VERIFIED or CAVEATS, the orchestrator does a dry-run merge into the target. If it conflicts, the run ends with exit 11 and no PR.
9. The verification gate. A fresh Claude Code session (`review-prompt.md`, the break-it lens, in its own container on a fresh clone; it never sees the judge's findings) writes JSON findings: BLOCKs, each with a shell command that reproduces the problem, and NOTEs. Then a container with no model and no credential (`verify.js`) runs every BLOCK's command at the pushed head and at the base, plus two checks on the changed test files (the base's tests against the head's code, the head's tests against the base's code). A BLOCK counts only when the machine reproduced it: a regression (fails at head, passes at base) or an unmet "Done when" clause (fails at both, clause named). A command that passes, times out or isn't found is invalid; one that fails at both with no clause is pre-existing, a note. Nothing reproduced: the PR. Something reproduced: one more worker round with those findings as facts, one more judge round, the push again, and the gate again (a gate cycle). The gate records every cycle in the manifest (`gate`) and the evidence files `gate-<n>-breakit.json` and `gate-<n>-verify.json`. A review or verifier that crashed, or left no valid record, is `gate_pending` (exit 12, infra: the batch retries the task once). No new commits in a cycle, the same command reproducing in a later cycle, REFUTED from the judge in a cycle, or a fourth cycle: `refuted` by the gate, exit 5, no PR.
10. The orchestrator opens the pull request itself, with the judge's verdict and findings and the gate's record in the body. It uses a separate `pull_requests:write` token that no container ever holds.
11. You review and merge. The target repo's ruleset requires one approval and green CI, and the GitHub App can't approve its own pull request. In merge mode (a task whose `base_branch` is `next`, and a merger App configured: see factory.md, "The merge gate") the factory merges the PR into `next` itself once the gate passed, the chain base is on `next`, the accumulation cap is not reached and the required checks are green; `merge` in the manifest says `merged`, `held`, `open` or `timeout` and why. You promote `next` to `main`.

| Verdict | Meaning | Result |
|---|---|---|
| `VERIFIED` | Checks pass, the judge couldn't break the change, and the scope is right. | PR opens if the branch merges cleanly and the verification gate reproduces nothing. |
| `CAVEATS` | The change does the task, but a human should look at something, such as code that could be deleted. | Another round if any remain, then the PR opens if the branch merges cleanly and the gate reproduces nothing. |
| `REFUTED` | A gating check (one the task names, or `npm test`) fails, the change is wrong or incomplete, the scope is wrong, or a test was weakened. | Another round if any remain, then the branch is pushed with no PR (exit 5). |
| none | The judge failed or didn't end with exactly one verdict line. | Branch pushed, no PR (exit 6). |

Each container gets exactly one secret, over stdin, written to a tmpfs: the worker and the gate's reviewer get an Anthropic token, the judge gets the Codex key, the push container gets the GitHub token, and the verifier gets nothing. The worker and judge never hold a GitHub token. The Anthropic and GitHub tokens expire within an hour. The Codex key lasts until you rotate it.

## Requirements

- A Mac with Docker Desktop running, `git` 2.38 or later, `jq` and `openssl`.
- A Keycard zone containing:
  - The `urn:factory:mini` Application, which is the orchestrator's identity.
  - The `https://api.anthropic.com` resource, issued as a one-hour Zone Provider token.
  - The `https://api.openai.com` resource, with the Codex API key stored as a Vault credential.
  - The `urn:factory:github-app-key` resource, with the GitHub App private key stored as a Vault credential (base64 PEM on one line).
  - Permits in the `software-factory-policies` policy set that allow the Application to reach all three resources.
- An Anthropic Workload Identity Federation rule that trusts the zone and maps it to the factory's service account and workspace.
- The GitHub App [`kmaida-software-factory`](https://github.com/apps/kmaida-software-factory), installed on each target repo.
- Optional: an [ntfy](https://ntfy.sh) topic for batch notifications.

## Install and configure

On the Mac that runs the factory:

```bash
git clone https://github.com/kmaida/software-factory.git
cd software-factory
docker build -t factory-sandbox .
```

Put the Keycard Application's client ID and secret in a directory outside the repo, one value per file:

```bash
mkdir -p ~/factory-secrets && chmod 700 ~/factory-secrets
printf '%s' '<client id>' > ~/factory-secrets/keycard_client_id
printf '%s' '<client secret>' > ~/factory-secrets/keycard_client_secret
chmod 400 ~/factory-secrets/*
```

These two files are the only credentials stored on the machine. The factory gets every other credential from Keycard for each run.

| Variable | Required | Purpose |
|---|---|---|
| `FACTORY_SECRETS_DIR` | Yes, for `run` and `batch` | The directory with `keycard_client_id` and `keycard_client_secret`. |
| `FACTORY_NOTIFY_URL` | No | Where `batch` posts notifications, for example `https://ntfy.sh/<topic>`. The topic name acts as the secret. |
| `FACTORY_QUEUE` | No | A queue directory other than `queue/`. |
| `FACTORY_GATE` | No | `0` skips the verification gate for a night (the manifest says `gate.result: skipped`); the escape hatch for the gate's first real nights. |
| `FACTORY_REVISE` | No | `0` turns revisions off for a batch: a blocked or refuted task stays as it ended and deep lint holds instead of rewriting (see "Revisions"). |
| `FACTORY_MAX_ROUNDS` | No | Worker and judge rounds per task. Defaults to 5. |
| `FACTORY_ALLOW_DIRTY` | No | Set to `1` to run from a checkout with uncommitted changes. For development only; the manifest marks the commit `-dirty`. |

The Keycard zone URL, the Anthropic federation IDs and the GitHub App ID are constants at the top of `factory`. None of them is a secret.

The factory refuses to run from a checkout with uncommitted changes, and it records its own commit in every manifest. Change the factory by pull request, then `git pull` on the Mac.

It also refuses to run on any image but the one named by `IMAGE_ID` at the top of `factory` (the local image ID, `docker image inspect --format '{{.Id}}' factory-sandbox`). A change to the `Dockerfile` lands in two steps: merge it and `git pull`, `docker build`, read the new ID, merge a one-line PR that sets `IMAGE_ID` to it, and `git pull` again. In between, `FACTORY_ALLOW_DIRTY=1` runs on the new image and the manifest records `image_pinned: false`.

## Prepare a target repo

Do this once for each repo the factory works in. [`keycard-sandbox/keycard-workshop-platform`](https://github.com/keycard-sandbox/keycard-workshop-platform) is a complete example.

1. Add the repo to the `kmaida-software-factory` installation for its account (Settings > Applications > Configure), or install the App on a new account from its [installation page](https://github.com/apps/kmaida-software-factory/installations/new).
2. Add a ruleset on `main` that requires a pull request, one approval, dismissal of stale approvals, and your CI check (for example `test`). Don't add the App to the bypass list. In a new repo with no CI yet, add the required check after the scaffold task (see [Writing tasks](#writing-tasks)) lands.
3. Workflows that run on `pull_request` must not use repository secrets. A `factory/*` branch is a same-repo branch, so its workflow runs receive the repo's secrets, and the worker can change any script those workflows run.
4. The judge runs the repo's checks in the container, on Node 24 (the image's Node line). Something like `npm ci && npm test` has to pass with no secrets and no services beyond what the tests start themselves.
5. Write a `CLAUDE.md` that gives the worker the repo's conventions, the check commands, and anything it must never weaken. Include this rule: if the task can't be completed, commit `docs/BLOCKED-<task_id>.md` with the reason and stop. `worker-prompt.md` asks for the same note; repeating it here keeps it in front of the worker. A branch with only that note ends with exit 10 and no PR, and the note's first line of text (headings skipped) becomes the reason in the manifest and the notification, instead of the run ending silently with exit 3. The judge doesn't follow `CLAUDE.md`: the factory removes it and other agent config files from the root of the judge's copy, and the judge prompt says to ignore any instructions in the repo.

## Writing tasks

A task is one JSON file in `queue/` in the factory checkout, with exactly four non-empty string fields:

```json
{
  "repo": "keycard-sandbox/keycard-workshop-platform",
  "base_branch": "main",
  "task_id": "010-scaffold",
  "instructions": "Goal: ...\n\nContext: ...\n\nScope: ...\n\nDone when: ...\n\nOut of scope: ..."
}
```

- Name the file `<task_id>.json`, and start `task_id` with a number so a batch runs in order: `010-scaffold`, `020-schema`, `030-auth-api`. To split a task, add one lowercase letter after the number: `019a-schema`, `019b-seed`. Don't end an ID in `.proposed`: deep lint uses that name for its proposals in `queue/held/`.
- Set `base_branch` to `main` unless the PR itself must target an unmerged branch. In a batch, each task's branch is cut from the last task that passed, while its PR still targets `main`.
- Write `instructions` under five headings, in this order, each on its own line. The judge gets this text verbatim, so "Done when" is its acceptance test and "Scope" and "Out of scope" are its refutation rules.

```text
Goal: one sentence describing what exists when the task is done.

Context: what to read first, the conventions, and the decisions already made (library, schema, API shape).

Scope: the files or directories this task may create or change. Everything else is off limits.

Done when: `npm test && npm run typecheck` passes, and <one observable behavior, stated concretely>.

Out of scope: what a helpful agent would be tempted to add. Do not touch <paths>. Do not add dependencies. If the task can't be completed, commit docs/BLOCKED-<task_id>.md with the reason.
```

Size tasks for an unattended run:

- One task is one PR you'd review in ten minutes: one module or one vertical slice, under about 300 lines of diff.
- Every task leaves the checks green on its own branch.
- Nothing needs a decision. Make the decision yourself and state it under Context.
- Nothing needs a secret, an account, or a network service the tests don't already have.
- A task that relies on a table, column, export or dependency either lists it under Scope or follows the task that adds it. Otherwise the worker finds it missing and blocks.
- A task that needs another task's work declares it (deep lint adds one you missed): `"depends_on": ["050b-web-auth"]`, a fifth, optional field listing task ids (base ids: a requeued `-r1` or a retried `-i1` of that task counts). `lint` prints the graph and refuses a dependency on the task itself, on an unknown id, on a task of another repo, or on a *later* task in the queue (filename order is the schedule: reorder instead). In a batch the dependency must be on the branch the task is cut from: passed tonight in chain mode, or merged into the base branch as GitHub says (a merged PR from `factory/<id>`, and no merged `Revert "factory: <id>"`). Otherwise the task **waits**: its file stays in the queue, it is visited once per night, and it runs the night after the dependency lands. The row says why: `open` (a PR awaits a human), `queued` (a run of it is still in the queue), `unknown` (GitHub or the run record could not be asked; notified, never a verdict), `reverted`, or `dead` (nothing queued, no PR open or merged, or merged into another branch than this task's base). Dead and reverted are notified and make the batch exit non-zero (with 1, since the waiting task has no run of its own; the root's own line on the phone has its status). This is what stops one failed root from taking its dependents down one by one. Ids ending in `-r<N>` or `-i<N>` are the factory's (requeues and retries) and normalise to the task they stand for; do not name tasks that way.
- A task that may add or change a dependency names `package.json` under Scope. Without that, a branch that changes a dependency manifest is pushed but gets no PR (exit 14).
- Scope is the contract, with one declared exception. When a "Done when" clause can only be met by a small edit to a file Scope does not name, and the edit is plainly what the task requires (an assertion that encoded the behaviour the task changes, a one-line include, export or type), the worker makes it and commits `docs/SCOPE-<task_id>.md`: one line per file, the edit and the clause. The judge rules on each line (accepted lines are CAVEATS, anything more is REFUTED as scope), the PR body carries the note under its own heading, the report row and the phone say `scope note`, and you read it before merging. A new dependency, another task's contract, another package, or more than a few lines is still a `BLOCKED` note. Before this (2026-11-05), four of five blocks in a week were a one-line assertion outside Scope, each costing a night and a spec PR.
- The judge's verdict is bounded by "Done when" and the base: a gating check, a MISSING clause, a regression against the base, scope, or a weakened test make it REFUTED; wrong behaviour on inputs "Done when" does not name is a `NOTE:` for the human, and with every clause DONE the verdict is CAVEATS and the PR opens with the notes. (072d passed every clause three nights running and was refuted at the round cap each time on a fresh edge case of HTML-to-markdown; its criterion has no last case.)
- Never put a token or key in a task. A task whose text looks like it carries one is refused before anything is minted (exit 13), and `lint` reports it.
- The first task in a new repo is the scaffold, the test runner and CI. Merge it and watch the judge run its checks once before you stack anything on it.

Keep "Done when" narrow. Anything beyond it is out of scope by default, and the judge returns CAVEATS for over-engineering, which costs the worker a revision round.

## Running it

```bash
export FACTORY_SECRETS_DIR=~/factory-secrets
export FACTORY_NOTIFY_URL='https://ntfy.sh/YOUR_TOPIC'   # optional
```

| Command | What it does |
|---|---|
| `./factory run <task-file>` | Runs one task. The task file stays where it is. |
| `./factory lint [dir]` | Checks a queue (default `queue/`) against the task rules: schema, `<number>-<name>` or `<number><letter>-<name>` IDs, filename matches `task_id`, the five headings in order, and `base_branch` order. |
| `./factory lint --deep [dir]` | One Codex session reads the queue and a clone of its base branch and reports, per task, what it relies on and who supplies it. Adds a missing `depends_on` in place and holds a task that can't pass as written. See [Deep lint](#deep-lint). |
| `./factory batch [dir] [flags]` | Runs a queue unattended, in filename order. Runs `lint` and refuses to start if it finds problems, then `lint --deep`, then `lint` again on what deep lint changed. |
| `./factory report [n]` | Shows the last `n` runs (default 20): run ID, exit status, judge rounds, verdict, the worker rounds' reported cost (`?` when a round left none) and PR URL. |
| `./factory requeue <queue/failed/file.json> [source-task.json]` | Copies a failed task back into the queue as `<task_id>-r<N>`, with the last attempt's judge findings or blocked reason added to its instructions. With a source (the task as its generator writes it today, same `task_id`), the rerun carries the source's instructions and `depends_on` instead of the failed file's: the way to rerun a task after its spec was fixed. |
| `./factory unhold <queue/held/file.json>` | Moves a held task back into the queue under its own ID, after you've edited it or accepted its proposal, and records the touch in `runs/touches.tsv`. |
| `./factory stop <run_id>` | Stops the run's container, blocks new runs, and records the stop in the run's log. |
| `./factory ruleset-check <owner/name>` | The negative tests of a repo's rulesets with real tokens (a push to `next` refused, a merge without `factory-gate` refused, a stale sha 409, an App approval or merge on `main` refused); run once after setting up `next` and the merger App. |
| `./canary.sh <owner/name>` | The factory's own canary queue against a throwaway repo: run after every factory merge and before a real night, asserts each run's manifest. |

### Before a real night

On the mini, after any factory merge, in this order:

1. `git -C ~/software-factory pull --ff-only`
2. Rebuild the image if the Dockerfile changed (the `IMAGE_ID` header in `factory` says how).
3. `./canary.sh kmaida/test-repo` and wait for exit 0. The canary repo needs a root `package.json` whose `npm test` passes, and its lockfile; without them the pass and manifest canaries end blocked.
4. `./factory batch queue --continue > runs/night.out 2>&1 &`
5. `caffeinate -i -w $! &`

Never skip step 3. The canary's task ids are as long as real ones; a hand-written smoke task with a short id proves only the short path (2026-11-02: the proxy's DNS name broke above 63 bytes, every real task failed, the smoke had passed).

### Deep lint

On the night of 2026-11-03, 11 tasks blocked, and every one was visible in the task file and `main` before the batch started: a missing `depends_on`, a route or transition no task creates, a Scope that can't hold what Done when needs, a file a human hadn't filled in yet. `batch` runs `factory lint --deep` once the queue passes `lint` and the batch holds the lock. One fresh Codex session (`deep-lint-prompt.md`, in the judge's container with the judge's model) reads the queue, its `done/`, `failed/` and `held/` archives and a clone of the base branch, all read-only. For each task it lists what the task relies on and where that comes from (the base, a named task, or nothing), and looks for contradictions, verbs a strict reviewer would read more broadly than Scope allows, and human inputs still blank.

The factory applies these and nothing else:

- **Additions.** `depends_on` becomes the task's own IDs plus each supplier the session named, in the same file under the same ID, and the task waits for them like any declared dependency. An ID is never removed: if the session drops one, it stays and the output says so. A paragraph naming the added IDs and the deep-lint run goes after Out of scope.
- **Holds.** A task with a prerequisite no task supplies, a contradiction, an ambiguity, a blank human input, or a supplier later in the queue moves to `queue/held/<id>.json`, unchanged, beside `<id>.reason` (one line) and `<id>.proposed.json` (the session's proposed fix, for you to read). Each hold is notified once. Until you release it, a held task counts as exit 10 in every batch, and a task that depends on it waits on a dead dependency.

- **Revisions.** With revisions on, a contradiction or an ambiguity that comes with a rewrite is not held: the rewrite replaces the instructions once a second model accepts it (see "Revisions" below).

With revisions off (merge mode, or `FACTORY_REVISE=0`), deep lint never changes Goal, Context, Scope, Done when or Out of scope, and never writes the model's words into a queued task. In merge mode its base is `next`, which agents wrote and nobody has read, so the only outputs that can't be steered into authority are a delay and a hold. The whole proposed queue goes through `lint` before anything is written, and if `lint` refuses it, nothing changes. If deep lint fails for any reason (no answer, an invalid answer, a proposal `lint` refuses, Docker, a token), the queue is untouched and the night runs on `lint` alone, with a notification. The one exception is a deep lint that dies between its renames: the notification then says the queue may be partly changed, and `deep_lint` in its manifest (`result: applying`) lists what it meant to do. `FACTORY_DEEP_LINT=0` skips it for one batch. `lint --deep` exits 0 when it applied its result (holds included), 1 when it refused to start (the queue fails `lint`, or has more than one repo or base branch), 6 when there was no valid answer or `lint` refused the proposal, 13 when the base looks like it holds a credential, and 15 when the base is red: before the model reads anything, the verifier (no model, no credential) runs the base's own `lint`, `typecheck` and `test` scripts at its tip, and a non-zero exit stops the night before any task runs, notified with the script and its exit (`health` in the manifest). A task cannot pass on a red base; it can only block itself on it, one worker at a time. `FACTORY_HEALTH=0` skips the check for one batch. Its evidence is in `runs/<timestamp>-deep-lint/`: `manifest.json` (with `deep_lint`: what was added, held and refused) and the whole answer in `deep-lint.json`.

To release a held task, edit `queue/held/<id>.json` or read `<id>.proposed.json`, then name the file you want queued:

```bash
./factory unhold queue/held/<id>.proposed.json
```

`unhold` writes it back as `queue/<id>.json` and removes the task's three held files. It takes the batch's lock, so run it when no batch is running, and it refuses if the queue would then fail `lint` (a proposal that depends on a later task: rename the files into order first). The next batch lints it and deep lint reads it again, so a hold whose cause is still there comes back. If you judge a hold wrong, run that night with `FACTORY_DEEP_LINT=0`.

### Revisions

A task whose own wording stops it used to cost a night: the agent blocked, the reviewers refuted every attempt, or deep lint held the task, and everything behind it waited for you. With revisions on (the default while the factory only opens PRs), the factory rewrites such a task once and runs the rewrite the same night:

- **After a block.** When a run ends blocked, a fresh Codex planner (`revise-prompt.md`) reads the attempt, the task and the agent's note. If it confirms that no agent could complete the task as written, it rewrites the instructions with the smallest change that removes the conflict. The batch queues the rewrite as `<id>-r1` and runs it next, with or without `--continue`, so the tasks that depend on it run after it. A `factory run` outside a batch never asks the planner.
- **After a refusal.** When a run ends refuted (by the judge's last round or by the verification gate), a fresh Codex planner (`revise-refuted-prompt.md`) reads the attempt, the task, the last judge review and the findings the gate reproduced. Most refuted attempts are the agent's fault, and those stay refuted. The planner rewrites the task only when a careful fresh agent would be refuted again for the same reason: two clauses in conflict, or findings about behaviour the task never decides under a "Done when" clause with no last case ("the tests prove every rule and case"). The rewrite bounds that clause to the rules and cases the task already lists, and decides an open case only where the task's Goal and other rules already imply the answer. It is queued and run as `<id>-r1`, like a rewrite after a block.
- **Before a run.** When deep lint would hold a task for a contradiction or an ambiguity and proposes a rewrite, the rewrite replaces the instructions in place, under the same ID. One deep lint revises at most three tasks this way and holds the rest.

Every rewrite passes three checks before it is used. A fresh Claude reviewer (`revise-review-prompt.md`) reads what the planner was given (the note, or the reviews that refuted the attempt), compares the rewrite with the task as written and must find nothing lost and nothing widened. The host refuses a rewrite that adds a workflow, a lockfile, test helpers or a catch-all to Scope. And the queue must still pass `lint`. A rewrite that fails a check is dropped and the task stays blocked, refuted or held, as before. The manifest says why: `revision` in the run's, `rewrite_not_used` on the hold in deep lint's. The Scope check is a backstop for literal paths and globs; the reviewer is the check on meaning.

You stay the authority. The PR of a revised task opens with "Task revised by the factory", the reason (and, after a block or a refusal, the clauses that changed) and the task as you wrote it, and `queue/revised/<id>.json` keeps that original. Close the PR if you disagree with the revision. The notification says `revised as <id>-r1`, or `<id> revised by deep lint`.

A task is revised once. A task that was already revised, and any `-r<N>` task that blocks or is refuted, wait for you. Revisions are off in merge mode, where nothing reads a PR before it merges into `next`.

`./deep-lint-replay.sh <keycard-workshop-platform checkout>` measures the prompt. It replays the 16 tasks of 2026-11-03 against `main` as it was that night and scores the answer: each of the 11 that blocked must be held or made to wait on something that wasn't there, and none of the 5 that passed may be held. Run it when you change `deep-lint-prompt.md` or `JUDGE_MODEL`. It calls Codex with your own login, so it isn't part of `test-factory.sh`.

### Batches

`batch` chains tasks. Each task cuts its branch from the last task in the batch that passed, so dependent tasks build on each other overnight without waiting for a merge. A failed task's branch is never used as a base. Every PR still targets its task's own `base_branch`, so a later PR shows the earlier tasks' commits until those merge. A chained queue must target one repo. If `base_branch` moved while the batch ran (a PR merged by hand), its tip is merged into the chain base before the task starts, so the task sees it (`base_merged` in the manifest; a conflict is left for the PR, `base_merge_conflict`).

| Flag | Effect |
|---|---|
| `--max-tasks N` | Stop after `N` tasks. |
| `--stop-at HH:MM` | Start no task after this local time today. If the time has already passed, nothing runs. To use a stop time after midnight, start the batch after midnight. |
| `--no-chain` | Base every task on its own `base_branch`. |
| `--continue` | Keep going after a failure. Tasks whose `base_branch` names a task that failed or was skipped in this batch are skipped too, and moved to `failed/<batch_id>-<task_id>.json` unrun. |

Every failed run is classed in its manifest as `task` (it cannot pass as specified: refuted, blocked, a dependency change, a credential in the input, no changes) or `infra` (something around it failed: no verdict, a conflict with a target that moved, a PR open that failed, a gate that could not fetch, a token, a proxy, a kill). A task failure moves the file to `queue/failed/` and, without `--continue`, stops the batch; the remaining tasks stay in the queue. An infra failure never stops the batch by itself: with nothing pushed (`pushed: false`) the file stays in the queue under its own id for the next night; with a branch pushed the task is retried once, next, as `<id>-i1` from the same chain base (a conflict with no chain head retries from the task's own base; mid-chain it is archived instead, since neither base would do), and a retry that fails the same way is the task's own failure. A stopped run (`factory stop`) is a task failure, never re-dispatched. Two infra failures in a row from different tasks stop the batch with the queue as it is. Exit 0, or `pr_failed` (judged and pushed, every gate clean, only the PR missing), moves the file to `queue/done/` and the chain goes on from it. Ids ending in `-i<N>` belong to the batch; do not write them by hand. Rerunning `batch` never repeats a task. A task whose `depends_on` is not yet on its base waits in the queue (see [Writing tasks](#writing-tasks)); a wait on a dead dependency counts as a failure. At the end, `batch` writes a report to `runs/batch-<timestamp>.md` with a note per row (`retrying as …`, `nothing pushed; left in queue`, `retry failed the same way`, `waiting on <id> (open|queued|dead)`), and exits with the status of the last task that did not pass tonight, 0 when every task passed, was recovered by its retry, or is waiting on something alive. A held task counts as 10 until you release it; any failure tonight decides the status first.

### Notifications

With `FACTORY_NOTIFY_URL` set, `batch` posts plain-text lines to it:

- For each task that fails: `<batch_id>: <task> exited <status> (<outcome or verdict>, continuing|stopped|retrying as <id>-i1|left in queue)`. The outcome is `blocked`, `dependency_change`, `conflict` or `gate_error` when a gate stopped the PR, or `credential_in_input` when the run refused to start; an infra failure says `infra: …`. A blocked task adds `: <reason>` from its note. A task that exits 4 sends a line too (open its PR by hand), although it counts as passed.
- For each task waiting on a dead dependency: `<batch_id>: <task> waiting on <id> (dead): nothing queued, no PR open or merged`. A wait on a live one (open PR, a run still queued) sends nothing; the report row says so.
- For each task deep lint holds, once: `<batch_id>: <task> held by deep lint (<kind>): <reason>`. If deep lint fails: `<batch_id>: deep lint failed (exit <n>, run <run_id>); the night runs on the deterministic lint`.
- Once when the batch ends, whatever happened: `<batch_id>: done: <n> run, <k> PR(s), <f> failed, <b> blocked, <i> infra, <w> waiting (<d> on a dead dependency), <h> held. All tasks ran.` (the blocked, infra, waiting and held counts appear only when they aren't zero) or `Stopped: <reason>. <m> task(s) left in queue (<w> waiting on a dependency).`

Passing and skipped tasks send nothing of their own, and skipped tasks don't count as run or failed. Passing tasks are quiet because GitHub already notifies you of each PR. A single `factory run` sends nothing.

`batch` prints `notify: <host>` (the host only, never the path, which carries the topic) or `notify: off (FACTORY_NOTIFY_URL not set)` after taking the lock, and the same in the report header; a POST that fails prints `notify: POST failed (curl exit N)` to stderr and the batch goes on. So if no message arrives at all, read the batch's output or the report header: `notify: off` means the variable was not in the batch's environment (put the `export` in `~/.zshenv`, not `~/.zshrc`: an ssh one-liner and launchd read no rc file); a `POST failed` line means the endpoint; neither means the batch never reached its end (lint, `HALT` or the lock refused it, or it was killed), and a batch refused at startup writes no report.

### Stopping

`factory stop <run_id>` writes a `HALT` file in the factory checkout. While `HALT` exists, `run` and `batch` refuse to start, and a running batch stops before its next task. Delete `HALT` to resume:

```bash
rm HALT
```

## Reading results

Each run leaves its evidence in `runs/<run_id>/`, where `run_id` is `<UTC timestamp>-<task_id>`:

| File | Contents |
|---|---|
| `manifest.json` | The task hash, repo, base commit, image ID and whether it is the pinned one, factory commit, Keycard zone, model, judge model and budget, GitHub App installation, commit identity, each worker round's status and reported cost, judge rounds and verdict, final commit, PR URL (or `pr_error`), exit status, the npm policy supplied to the containers, and, when a gate stopped the PR or the run stopped itself, `outcome` (`blocked`, `dependency_change`, `conflict`, `gate_error`, `credential_in_input` or `evidence_error`) and its `reason`. |
| `log.jsonl` | Every line the containers wrote, with each container's credential redacted, plus the orchestrator's own events. |
| `judge-<round>.md` | The judge's full review for each round. |

| Exit | Meaning |
|---|---|
| `0` | The PR is open. |
| `3` | The worker made no changes. Nothing was pushed. |
| `4` | The branch was pushed, but opening the PR failed (`outcome: pr_failed`). `pr_error` in the manifest has the HTTP status and body. |
| `5` | The judge refuted the final round, or the verification gate refuted the branch (`refuted_by: gate` in the manifest: no new commits in a cycle, the same reproduced command twice, REFUTED in a cycle, or four cycles). The branch was pushed with no PR. In a batch with revisions on, the task may run again the same night as `<id>-r1` when its own wording was the cause (see "Revisions"). |
| `6` | The judge gave no verdict. The branch was pushed with no PR. |
| `10` | Blocked: the task's `docs/BLOCKED-<task_id>.md` note is at the pushed head. `reason` in the manifest has its first line; `judge.rounds` is 0 when the note came in round 1. No PR. |
| `11` | The branch conflicts with the current target branch. No PR. |
| `12` | A gate couldn't run (the credential scan of the base tree, or the fetch, diff or merge-check of the branch; the end of `log.jsonl` has git's output), the verification gate left no valid record (`outcome: gate_pending`: a review or verifier that crashed, invalid findings, a failed install; the branch is judged and pushed, only the gate is missing), or the log pipeline failed during a step (`outcome: evidence_error`): the run stopped there. No PR. If that step was the push, the branch may already be on GitHub and `final_sha` says which commit. |
| `13` | Refused to start: the task text or the base tree contains something shaped like a credential. `reason` names the file (or `instructions`), never the content. No container ran and no agent credential was issued; the task-text check runs before anything is minted, the tree check after the clone, so by then the one-hour clone token exists. |
| `14` | The branch changes a dependency manifest (`package.json`, a lockfile) and the task's Scope doesn't name `package.json`. The branch was pushed with no PR; `reason` lists the files. |
| Other | The orchestrator or a worker round failed. Check the end of `log.jsonl` and the factory's stderr. |

Every non-zero exit also carries `class` (`task` or `infra`) and `pushed` (`true`, `false`, or `null` when the push step started and its result is unknown; `final_sha` is set only on a successful push, and a failed one records `outcome: push_failed`). `batch` reads both: see [Batches](#batches).

In the morning, run `./factory report`, then review the stacked PRs from the bottom up. Merge the oldest first, and each later PR's diff shrinks to its own commits.

To retry a failed task, fix whatever blocked it, then requeue it and run `batch` again:

```bash
./factory requeue queue/failed/<file>.json
```

`requeue` gives the task a new ID, `<task_id>-r<N>`, because its old `factory/<task_id>` branch still exists. It adds the blocked reason or the last judge review only when the archived file is from a run that has one; a skipped task gets none. It keeps `base_branch` as it was, so update any task that names the old ID. `batch` never requeues on its own, so a task that fails the same way twice doesn't run a third time.

## Security model

The orchestrator is the trust boundary, not the container. It builds every `docker run` command from a fixed schema, and nothing the agent writes can change the image, mounts, flags, repo or token scope. Task text, repo contents and tool output are all untrusted input.

The table compares the factory to the controls in the reference architecture's appendix.

| Boundary | The architecture asks for | The factory does | Status |
|---|---|---|---|
| Sandbox | A fresh, hardened sandbox per task, unprivileged, writes confined to the workspace, resource limits, destroyed afterward | A fresh container per step: non-root, read-only root filesystem, all capabilities dropped, `no-new-privileges`, 4 GB memory, 2 CPUs, 512 processes, one-hour timeout, no Docker socket, only the clone mounted (the judge also gets its own scratch and output directories), removed on exit | Meets |
| Sandbox | A microVM for untrusted code; process, file and network activity recorded outside the agent | Containers share the Docker Desktop VM; only the agent's own output stream and its outbound connections, by host, are recorded | Partial |
| Network | Default-deny egress proxy that all traffic passes through | Each step runs on an internal Docker network with no route out. Its only exit is a proxy container started for that step with that step's hosts (worker: Anthropic and npm; judge: OpenAI and npm; push: GitHub); it allows `CONNECT` on 443 to those and refuses everything else, and every decision goes into the run's log. It filters by host, not by request, and the credential still travels inside the container | Partial |
| Identity and access | Credentials attached at the proxy, never inside the sandbox | Each container holds one short-lived credential | Gap |
| Identity and access | Its own identity per agent, short-lived task-scoped credentials, independent approval, fail-closed | One shared Application identity, `urn:factory:mini`, not one per agent, and a run ID per run in the manifest; one-hour Anthropic and GitHub tokens, the GitHub tokens scoped to one repo, but a long-lived Codex key; ruleset requires a human approval the App can't give; the run refuses to start on any token or schema failure | Partial |
| Identity and access | Revoke any grant at any time | `factory stop` kills the run and blocks dispatch; tokens aren't revoked, they expire within an hour | Partial |
| Supply chain | Packages admitted only through an approved registry or firewall | Packages still come straight from the public registry (through the step's proxy). The containers get `npm` defaults that turn install scripts off and keep `npm install` from resolving anything published in the last seven days, recorded in the manifest as supplied policy (the agent could override them). A PR that changes a dependency manifest gets no PR unless the task's Scope names `package.json`; that gate runs after the package has already been installed and run in the containers | Partial |
| Supply chain | No credentials in the inputs an agent receives | The task text and the tree the worker checks out are screened for common token shapes before any agent credential is issued or any container runs; the run refuses to start and names the file, not the content. Git history and other branches in the clone are not screened | Partial |
| Supply chain | Approved, pinned components | Base image, Claude Code and Codex are pinned in the `Dockerfile`, and `factory` refuses to run on any image but the one whose ID it carries (`IMAGE_ID`), so the image changes only by reviewed PR | Meets |
| Inference | Model gateway, approved models, per-task spend limits | Claude Code and Codex still call their APIs directly, through the step's proxy. Each is pinned to one full model ID, the worker runs under a per-round spend cap (Claude Code's own estimate, so it can overshoot; a worker calling the API itself is outside it), and each worker round's reported cost is in the manifest and `report`. Codex has no cap; the consoles' hard spend limits are the backstop | Partial |
| Execution | Start each agent only with granted access; stop on demand | Keycard policy grants each credential; `factory stop` | Meets |
| Observability | Records linked by run ID, tamper-evident, outside the agent's reach; versioned factory configuration | Manifest, log and judge reviews keyed by run ID and written by the orchestrator, not the agent, owner-readable only; factory commit and image ID recorded; Keycard audits every grant; a run whose log pipeline fails stops there with `outcome: evidence_error` rather than continue unrecorded; the files aren't tamper-evident | Partial |
| Validation | Verify every output before it advances | Independent judge on a fresh clone, plus required CI and a human review | Meets |

Known limits:

- Egress is limited to each step's hosts, but a key read inside a container can still leave through an allowed host (npm and OpenAI both accept uploads) or through the judge's findings, which become the next prompt and the PR body. The judge runs the repo's tests as the same user as Codex, so a test the worker wrote can read the judge's key.
- GitHub can't scope an installation token to one branch, so the push token can push to any branch of the target repo that no rule protects.
- The Keycard client secret is a long-lived static secret on the Mac. It never enters a container.
- Redaction catches each container's token literally, base64- and URL-encoded (in that container's output, and the judge's key in its review), and anything shaped like a common token wherever text leaves the run (the log, the judge's review and so the next prompt and PR body, a blocked reason, `pr_error`, notifications), but not a token split across lines or otherwise transformed.

## Repo layout

| Path | Contents |
|---|---|
| `factory` | The orchestrator (bash 3.2, macOS). |
| `Dockerfile` | The sandbox image and its entrypoint, with three modes: `work`, `judge` and `push`. |
| `proxy.js` | The per-step egress proxy: `CONNECT` to that step's allowlisted hosts on 443, nothing else. Runs in the sandbox image. |
| `worker-prompt.md` | The house rules every worker round starts with. |
| `judge-prompt.md` | The judge's instructions. They live here, not in the target repo, so the worker can't change them. |
| `deep-lint-prompt.md` | Deep lint's instructions: prerequisites, contradictions, ambiguity, human inputs, and the JSON answer. |
| `revise-prompt.md`, `revise-refuted-prompt.md`, `revise-review-prompt.md` | Revisions: the planner that rewrites a blocked task, the planner that rewrites a refuted one, and the reviewer that must accept every rewrite. |
| `deep-lint-replay.sh` | Scores `deep-lint-prompt.md` against the 2026-11-03 night's 16 tasks with a real Codex call. |
| `test-factory.sh` | Tests the orchestrator against stubbed `docker` and `curl`. |
| `docs/flow.svg`, `docs/flow.json` | The run diagram and its [archify](https://github.com/tt-a1i/archify) source. |
| `docs/demo.md` | A short demo script. |
| `factory.md` | Design notes, decisions and history. |
| `docs/hardening-plan.md` | The design note behind the PR gates, five rounds, chaining past failures and `requeue`. |
| `queue/`, `runs/` | Task files and run evidence. Host state, not committed. |
