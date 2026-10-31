# software-factory

The software factory turns a task file into a reviewed pull request. You write a task, and the factory runs Claude Code in a locked-down container against a fresh clone of the target repo. Codex reviews the result in a second container and tries to refute it. If the work survives review, the factory opens a pull request for a human to approve. The factory never merges.

It is a Level 2 (workflow-orchestrated) factory in the terms of the [Agent Baseline Secure Software Factory reference architecture](https://agentbaseline.org/reference-architecture). [Security model](#security-model) lists where it meets that architecture and where it doesn't yet.

## How it works

![The factory's run loop: a task file goes to the orchestrator, which gets credentials from Keycard and runs the worker, judge and push containers, then opens a pull request for human review](docs/flow.svg)

One run takes one task through these steps:

1. The orchestrator (`factory`, a bash script on the Mac mini) checks the task file, takes the one-job lock, and writes `runs/<run_id>/manifest.json` before it issues any credential.
2. It gets the GitHub App private key from Keycard Vault, mints a one-hour installation token scoped to the target repo, and clones the repo.
3. It gets a one-hour Anthropic token (Keycard issues a signed token, and Anthropic Workload Identity Federation exchanges it) and starts the worker container. Claude Code reads `worker-prompt.md` and the task, then commits on `factory/<task_id>`. If the worker changes nothing, the run ends with exit 3.
4. The orchestrator gets the Codex key from Keycard Vault and starts the judge container on a read-only copy of the worker's tree. Codex follows `judge-prompt.md`: it reads the diff, runs the repo's checks, looks for bugs, scope creep, weakened tests and over-engineering, and ends with one verdict.
5. Any verdict except VERIFIED goes back to the worker with the judge's findings, for up to three rounds.
6. A push container pushes the branch with a fresh `contents:write` token. The branch is pushed whatever the verdict, so you always have the evidence.
7. On VERIFIED or CAVEATS, the orchestrator opens the pull request itself, with the judge's verdict and findings in the body. It uses a separate `pull_requests:write` token that no container ever holds.
8. You review and merge. The target repo's ruleset requires one approval and green CI, and the GitHub App can't approve its own pull request.

| Verdict | Meaning | Result |
|---|---|---|
| `VERIFIED` | Checks pass, the judge couldn't break the change, and the scope is right. | PR opens. |
| `CAVEATS` | The change does the task, but a human should look at something, such as code that could be deleted. | Another round if any remain, then the PR opens. |
| `REFUTED` | A check fails, the change is wrong or incomplete, the scope is wrong, or a test was weakened. | Another round if any remain, then the branch is pushed with no PR (exit 5). |
| none | The judge failed or didn't end with exactly one verdict line. | Branch pushed, no PR (exit 6). |

Each container gets exactly one secret, over stdin, written to a tmpfs: the worker gets the Anthropic token, the judge gets the Codex key, and the push container gets the GitHub token. The worker and judge never hold a GitHub token. The Anthropic and GitHub tokens expire within an hour. The Codex key lasts until you rotate it.

## Requirements

- A Mac with Docker Desktop running, `git`, `jq` and `openssl`.
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
| `FACTORY_ALLOW_DIRTY` | No | Set to `1` to run from a checkout with uncommitted changes. For development only; the manifest marks the commit `-dirty`. |

The Keycard zone URL, the Anthropic federation IDs and the GitHub App ID are constants at the top of `factory`. None of them is a secret.

The factory refuses to run from a checkout with uncommitted changes, and it records its own commit in every manifest. Change the factory by pull request, then `git pull` on the Mac.

## Prepare a target repo

Do this once for each repo the factory works in. [`keycard-sandbox/keycard-workshop-platform`](https://github.com/keycard-sandbox/keycard-workshop-platform) is a complete example.

1. Add the repo to the `kmaida-software-factory` installation for its account (Settings > Applications > Configure), or install the App on a new account from its [installation page](https://github.com/apps/kmaida-software-factory/installations/new).
2. Add a ruleset on `main` that requires a pull request, one approval, dismissal of stale approvals, and your CI check (for example `test`). Don't add the App to the bypass list. In a new repo with no CI yet, add the required check after the scaffold task (see [Writing tasks](#writing-tasks)) lands.
3. Workflows that run on `pull_request` must not use repository secrets. A `factory/*` branch is a same-repo branch, so its workflow runs receive the repo's secrets, and the worker can change any script those workflows run.
4. The judge runs the repo's checks in the container, on Node 24 (the image's Node line). Something like `npm ci && npm test` has to pass with no secrets and no services beyond what the tests start themselves.
5. Write a `CLAUDE.md` that gives the worker the repo's conventions, the check commands, and anything it must never weaken. Include this rule: if the task can't be completed, commit `docs/BLOCKED-<task_id>.md` with the reason and stop. The judge then refutes the branch with that reason in front of it, instead of the run ending silently with exit 3. The judge never reads `CLAUDE.md`; the factory removes it, along with other agent config files, from the judge's copy.

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

- Name the file `<task_id>.json`, and start `task_id` with a number so a batch runs in order: `010-scaffold`, `020-schema`, `030-auth-api`.
- Set `base_branch` to `main` unless the PR itself must target an unmerged branch. In a batch, each task's branch is cut from the previous task's branch anyway, while its PR still targets `main`.
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
- The first task in a new repo is the scaffold, the test runner and CI. Merge it and watch the judge run its checks once before you stack anything on it.

Keep "Done when" narrow. Anything beyond it is out of scope by default, and the judge returns CAVEATS for over-engineering, which costs the worker a revision round.

## Running it

```bash
export FACTORY_SECRETS_DIR=~/factory-secrets
export FACTORY_NOTIFY_URL=https://ntfy.sh/<topic>   # optional
```

| Command | What it does |
|---|---|
| `./factory run <task-file>` | Runs one task. The task file stays where it is. |
| `./factory lint [dir]` | Checks a queue (default `queue/`) against the task rules: schema, `<number>-<name>` IDs, filename matches `task_id`, the five headings in order, and `base_branch` order. |
| `./factory batch [dir] [flags]` | Runs a queue unattended, in filename order. Runs `lint` first and refuses to start if it finds problems. |
| `./factory report [n]` | Shows the last `n` runs (default 20): run ID, exit status, judge rounds, verdict and PR URL. |
| `./factory stop <run_id>` | Stops the run's container, blocks new runs, and records the stop in the run's log. |

### Batches

`batch` chains tasks. Each task after a successful one cuts its branch from the previous task's branch, so dependent tasks build on each other overnight without waiting for a merge. Every PR still targets its task's own `base_branch`, so a later PR shows the earlier tasks' commits until those merge. A chained queue must target one repo.

| Flag | Effect |
|---|---|
| `--max-tasks N` | Stop after `N` tasks. |
| `--stop-at HH:MM` | Start no task after this local time today. If the time has already passed, nothing runs. To use a stop time after midnight, start the batch after midnight. |
| `--no-chain` | Base every task on its own `base_branch`. |
| `--continue` | Keep going after a failure. Tasks that build on a failed task are skipped and moved to `failed/` unrun. |

By default, the first failure (any exit other than 0) stops the batch, and the remaining tasks stay in the queue. After each task, `batch` moves its file to `queue/done/` on exit 0 or to `queue/failed/` otherwise, so rerunning `batch` never repeats a task. At the end, `batch` writes a report to `runs/batch-<timestamp>.md`.

### Notifications

With `FACTORY_NOTIFY_URL` set, `batch` posts plain-text lines to it:

- For each task that fails: `<batch_id>: <task> exited <status> (<verdict>, continuing|stopped)`.
- Once when the batch ends, whatever happened: `<batch_id>: done: <n> run, <k> PR(s), <f> failed. All tasks ran.` or `Stopped: <reason>. <m> task(s) left in queue.`

Passing tasks send nothing of their own, because GitHub already notifies you of each PR. If no message arrives at all, the batch never reached its end (lint, `HALT` or the lock refused it, or it was killed), or the endpoint was unreachable. The batch report tells you which. A single `factory run` sends nothing.

### Stopping

`factory stop <run_id>` writes a `HALT` file in the factory checkout. While `HALT` exists, `run` and `batch` refuse to start, and a running batch stops before its next task. Delete `HALT` to resume:

```bash
rm HALT
```

## Reading results

Each run leaves its evidence in `runs/<run_id>/`, where `run_id` is `<UTC timestamp>-<task_id>`:

| File | Contents |
|---|---|
| `manifest.json` | The task hash, repo, base commit, image ID, factory commit, Keycard zone, GitHub App installation, commit identity, judge rounds and verdict, final commit, PR URL (or `pr_error`), and exit status. |
| `log.jsonl` | Every line the containers wrote, plus the orchestrator's own events, with both tokens redacted. |
| `judge-<round>.md` | The judge's full review for each round. |

| Exit | Meaning |
|---|---|
| `0` | The PR is open. |
| `3` | The worker made no changes. Nothing was pushed. |
| `4` | The branch was pushed, but opening the PR failed. `pr_error` in the manifest has the HTTP status and body. |
| `5` | The judge refuted the final round. The branch was pushed with no PR. |
| `6` | The judge gave no verdict. The branch was pushed with no PR. |
| Other | The orchestrator or a worker round failed. Check the end of `log.jsonl` and the factory's stderr. |

In the morning, run `./factory report`, then review the stacked PRs from the bottom up. Merge the oldest first, and each later PR's diff shrinks to its own commits.

To retry a failed task, copy its file from `queue/failed/` back into the queue with a new `task_id` and filename (its old `factory/<task_id>` branch still exists, so the old ID is refused). Add the judge's findings to its instructions, then run `batch` again.

## Security model

The orchestrator is the trust boundary, not the container. It builds every `docker run` command from a fixed schema, and nothing the agent writes can change the image, mounts, flags, repo or token scope. Task text, repo contents and tool output are all untrusted input.

The table compares the factory to the controls in the reference architecture's appendix.

| Boundary | The architecture asks for | The factory does | Status |
|---|---|---|---|
| Sandbox | A fresh, hardened sandbox per task, unprivileged, writes confined to the workspace, resource limits, destroyed afterward | A fresh container per step: non-root, read-only root filesystem, all capabilities dropped, `no-new-privileges`, 4 GB memory, 2 CPUs, 512 processes, one-hour timeout, no Docker socket, only the clone mounted, removed on exit | Meets |
| Sandbox | A microVM for untrusted code; process, file and network activity recorded outside the agent | Containers share the Docker Desktop VM; only the agent's own output stream is recorded | Partial |
| Network | Default-deny egress proxy that all traffic passes through | Egress is open | Gap |
| Identity and access | Credentials attached at the proxy, never inside the sandbox | Each container holds one short-lived credential | Gap |
| Identity and access | Its own identity per agent, short-lived task-scoped credentials, independent approval, fail-closed | `urn:factory:mini` per run in the manifest; one-hour tokens scoped to one repo; ruleset requires a human approval the App can't give; the run refuses to start on any token or schema failure | Meets |
| Identity and access | Revoke any grant at any time | `factory stop` kills the run and blocks dispatch; tokens aren't revoked, they expire within an hour | Partial |
| Supply chain | Packages admitted only through an approved registry or firewall | `npm ci` reaches the public registry directly | Gap |
| Supply chain | Approved, pinned components | Base image and Codex are pinned; Claude Code is installed at its latest version when the image is built | Partial |
| Inference | Model gateway, approved models, per-task spend limits | Claude Code and Codex call their APIs directly, with no spend limit per task | Gap |
| Execution | Start each agent only with granted access; stop on demand | Keycard policy grants each credential; `factory stop` | Meets |
| Observability | Records linked by run ID, tamper-evident, outside the agent's reach; versioned factory configuration | Manifest, log and judge reviews keyed by run ID and written by the orchestrator, not the agent; factory commit and image ID recorded; Keycard audits every grant; the files aren't tamper-evident | Partial |
| Validation | Verify every output before it advances | Independent judge on a fresh clone, plus required CI and a human review | Meets |

Known limits:

- Open egress lets the worker send the repo or its Anthropic token anywhere over HTTPS. The judge runs the repo's tests as the same user as Codex, so a test the worker wrote can read the judge's key.
- GitHub can't scope an installation token to one branch, so the push token can push to any branch of the target repo that no rule protects.
- The Keycard client secret is a long-lived static secret on the Mac. It never enters a container.
- Log redaction catches the literal tokens and their Basic-auth form, but not an encoded or split token.

## Repo layout

| Path | Contents |
|---|---|
| `factory` | The orchestrator (bash 3.2, macOS). |
| `Dockerfile` | The sandbox image and its entrypoint, with three modes: `work`, `judge` and `push`. |
| `worker-prompt.md` | The house rules every worker round starts with. |
| `judge-prompt.md` | The judge's instructions. They live here, not in the target repo, so the worker can't change them. |
| `test-factory.sh` | Tests the orchestrator against stubbed `docker` and `curl`. |
| `docs/flow.svg`, `docs/flow.json` | The run diagram and its [archify](https://github.com/tt-a1i/archify) source. |
| `docs/demo.md` | A short demo script. |
| `factory.md` | Design notes, decisions and history. |
| `queue/`, `runs/` | Task files and run evidence. Host state, not committed. |
