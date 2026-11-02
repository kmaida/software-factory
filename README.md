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
7. The orchestrator fetches the pushed branch and the current target branch into a fresh bare repo on the host. If the branch's only change is a `docs/BLOCKED-*` note, the run ends with exit 10 and no PR, whatever the verdict.
8. On VERIFIED or CAVEATS, the orchestrator does a dry-run merge into the target. If it conflicts, the run ends with exit 11 and no PR. If it merges cleanly, the orchestrator opens the pull request itself, with the judge's verdict and findings in the body. It uses a separate `pull_requests:write` token that no container ever holds.
9. You review and merge. The target repo's ruleset requires one approval and green CI, and the GitHub App can't approve its own pull request.

| Verdict | Meaning | Result |
|---|---|---|
| `VERIFIED` | Checks pass, the judge couldn't break the change, and the scope is right. | PR opens if the branch merges cleanly. |
| `CAVEATS` | The change does the task, but a human should look at something, such as code that could be deleted. | Another round if any remain, then the PR opens if the branch merges cleanly. |
| `REFUTED` | A gating check (one the task names, or `npm test`) fails, the change is wrong or incomplete, the scope is wrong, or a test was weakened. | Another round if any remain, then the branch is pushed with no PR (exit 5). |
| none | The judge failed or didn't end with exactly one verdict line. | Branch pushed, no PR (exit 6). |

Each container gets exactly one secret, over stdin, written to a tmpfs: the worker gets the Anthropic token, the judge gets the Codex key, and the push container gets the GitHub token. The worker and judge never hold a GitHub token. The Anthropic and GitHub tokens expire within an hour. The Codex key lasts until you rotate it.

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
| `FACTORY_MAX_ROUNDS` | No | Worker and judge rounds per task. Defaults to 5. |
| `FACTORY_BUDGET_USD` | No | The worker's spend cap per round, passed to Claude Code as `--max-budget-usd`. Defaults to 10. |
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

- Name the file `<task_id>.json`, and start `task_id` with a number so a batch runs in order: `010-scaffold`, `020-schema`, `030-auth-api`. To split a task, add one lowercase letter after the number: `019a-schema`, `019b-seed`.
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
- A task that needs another task's work declares it: `"depends_on": ["050b-web-auth"]`, a fifth, optional field listing task ids (base ids: a requeued `-r1` or a retried `-i1` of that task counts). `lint` prints the graph and refuses a dependency on the task itself, on an unknown id, on a task of another repo, or on a *later* task in the queue (filename order is the schedule: reorder instead). In a batch the dependency must be on the branch the task is cut from: passed tonight in chain mode, or merged into the base branch as GitHub says (a merged PR from `factory/<id>`, and no merged `Revert "factory: <id>"`). Otherwise the task **waits**: its file stays in the queue, it is visited once per night, and it runs the night after the dependency lands. The row says why: `open` (a PR awaits a human), `queued` (a run of it is still in the queue), `unknown` (GitHub or the run record could not be asked; notified, never a verdict), `reverted`, or `dead` (nothing queued, no PR open or merged, or merged into another branch than this task's base). Dead and reverted are notified and make the batch exit non-zero (with 1, since the waiting task has no run of its own; the root's own line on the phone has its status). This is what stops one failed root from taking its dependents down one by one. Ids ending in `-r<N>` or `-i<N>` are the factory's (requeues and retries) and normalise to the task they stand for; do not name tasks that way.
- A task that may add or change a dependency names `package.json` under Scope. Without that, a branch that changes a dependency manifest is pushed but gets no PR (exit 14).
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
| `./factory batch [dir] [flags]` | Runs a queue unattended, in filename order. Runs `lint` first and refuses to start if it finds problems. |
| `./factory report [n]` | Shows the last `n` runs (default 20): run ID, exit status, judge rounds, verdict, the worker rounds' reported cost (`?` when a round left none) and PR URL. |
| `./factory requeue <queue/failed/file.json>` | Copies a failed task back into the queue as `<task_id>-r<N>`, with the last attempt's judge findings or blocked reason added to its instructions. |
| `./factory stop <run_id>` | Stops the run's container, blocks new runs, and records the stop in the run's log. |

### Batches

`batch` chains tasks. Each task cuts its branch from the last task in the batch that passed, so dependent tasks build on each other overnight without waiting for a merge. A failed task's branch is never used as a base. Every PR still targets its task's own `base_branch`, so a later PR shows the earlier tasks' commits until those merge. A chained queue must target one repo.

| Flag | Effect |
|---|---|
| `--max-tasks N` | Stop after `N` tasks. |
| `--stop-at HH:MM` | Start no task after this local time today. If the time has already passed, nothing runs. To use a stop time after midnight, start the batch after midnight. |
| `--no-chain` | Base every task on its own `base_branch`. |
| `--continue` | Keep going after a failure. Tasks whose `base_branch` names a task that failed or was skipped in this batch are skipped too, and moved to `failed/<batch_id>-<task_id>.json` unrun. |

Every failed run is classed in its manifest as `task` (it cannot pass as specified: refuted, blocked, a dependency change, a credential in the input, no changes) or `infra` (something around it failed: no verdict, a conflict with a target that moved, a PR open that failed, a gate that could not fetch, a token, a proxy, a kill). A task failure moves the file to `queue/failed/` and, without `--continue`, stops the batch; the remaining tasks stay in the queue. An infra failure never stops the batch by itself: with nothing pushed (`pushed: false`) the file stays in the queue under its own id for the next night; with a branch pushed the task is retried once, next, as `<id>-i1` from the same chain base (a conflict with no chain head retries from the task's own base; mid-chain it is archived instead, since neither base would do), and a retry that fails the same way is the task's own failure. A stopped run (`factory stop`) is a task failure, never re-dispatched. Two infra failures in a row from different tasks stop the batch with the queue as it is. Exit 0, or `pr_failed` (judged and pushed, every gate clean, only the PR missing), moves the file to `queue/done/` and the chain goes on from it. Ids ending in `-i<N>` belong to the batch; do not write them by hand. Rerunning `batch` never repeats a task. A task whose `depends_on` is not yet on its base waits in the queue (see [Writing tasks](#writing-tasks)); a wait on a dead dependency counts as a failure. At the end, `batch` writes a report to `runs/batch-<timestamp>.md` with a note per row (`retrying as …`, `nothing pushed; left in queue`, `retry failed the same way`, `waiting on <id> (open|queued|dead)`), and exits with the status of the last task that did not pass tonight, 0 when every task passed, was recovered by its retry, or is waiting on something alive.

### Notifications

With `FACTORY_NOTIFY_URL` set, `batch` posts plain-text lines to it:

- For each task that fails: `<batch_id>: <task> exited <status> (<outcome or verdict>, continuing|stopped|retrying as <id>-i1|left in queue)`. The outcome is `blocked`, `dependency_change`, `conflict` or `gate_error` when a gate stopped the PR, or `credential_in_input` when the run refused to start; an infra failure says `infra: …`. A blocked task adds `: <reason>` from its note. A task that exits 4 sends a line too (open its PR by hand), although it counts as passed.
- For each task waiting on a dead dependency: `<batch_id>: <task> waiting on <id> (dead): nothing queued, no PR open or merged`. A wait on a live one (open PR, a run still queued) sends nothing; the report row says so.
- Once when the batch ends, whatever happened: `<batch_id>: done: <n> run, <k> PR(s), <f> failed, <b> blocked, <i> infra, <w> waiting (<d> on a dead dependency). All tasks ran.` (the blocked, infra and waiting counts appear only when they aren't zero) or `Stopped: <reason>. <m> task(s) left in queue (<w> waiting on a dependency).`

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
| `5` | The judge refuted the final round. The branch was pushed with no PR. |
| `6` | The judge gave no verdict. The branch was pushed with no PR. |
| `10` | Blocked: the branch's only change is a `docs/BLOCKED-*` note. `reason` in the manifest has its first line. No PR. |
| `11` | The branch conflicts with the current target branch. No PR. |
| `12` | A gate couldn't run (the credential scan of the base tree, or the fetch, diff or merge-check of the branch; the end of `log.jsonl` has git's output), or the log pipeline failed during a step (`outcome: evidence_error`): the run stopped there. No PR. If that step was the push, the branch may already be on GitHub and `final_sha` says which commit. |
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
| `test-factory.sh` | Tests the orchestrator against stubbed `docker` and `curl`. |
| `docs/flow.svg`, `docs/flow.json` | The run diagram and its [archify](https://github.com/tt-a1i/archify) source. |
| `docs/demo.md` | A short demo script. |
| `factory.md` | Design notes, decisions and history. |
| `docs/hardening-plan.md` | The design note behind the PR gates, five rounds, chaining past failures and `requeue`. |
| `queue/`, `runs/` | Task files and run evidence. Host state, not committed. |
