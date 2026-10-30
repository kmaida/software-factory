# software-factory

A personal software factory on an isolated Mac mini. A task file names a repo, a base branch and instructions; the orchestrator runs Claude Code in a locked-down container against a fresh clone and opens a pull request that a human must approve. The spec, the design decisions and the current state are in [`factory.md`](factory.md).

## Layout

- `factory` — the orchestrator (bash 3.2, macOS). `factory run <task-file>`, `factory lint [dir]`, `factory batch [queue-dir] [--max-tasks N] [--stop-at HH:MM] [--no-chain] [--continue]`, `factory report [n]`, `factory stop <run_id>`.
- `Dockerfile` — the sandbox image: Node, git, Claude Code, Codex (pinned), non-root user. One entrypoint, three modes (`work`, `judge`, `push`), each run as its own container with exactly one secret over stdin. No `gh`: the push token can only push.
- `worker-prompt.md` — the house rules every worker round opens with: least code that satisfies "Done when", no speculative abstraction, one test per behaviour.
- `judge-prompt.md` — what the Codex judge is told, including over-engineering as a finding. Both prompts live here, not in the target repo, so the worker cannot rewrite them.
- `tasks.md` — how to write a task file: naming, stacking, the five-heading instructions body, sizing. `factory lint` checks the queue against it.
- `test-factory.sh` — stubbed `docker`/`curl` check of the worker → judge → push loop.
- `factory.md` — spec, Agent Baseline mapping, implementation notes, TODO.
- `queue/` — task files, one JSON object each: `repo`, `base_branch`, `task_id`, `instructions`. `batch` runs them in filename order and moves each to `queue/done/` or `queue/failed/`. Host state, not committed.
- `runs/<run_id>/` — per-run evidence: `manifest.json`, `log.jsonl` and one `judge-<round>.md` per review. Host state, not committed.

## How a run works

1. The orchestrator validates the task file, takes a lock, and writes a manifest naming the run, the task, the base commit, the image digest and its own commit.
2. It fetches the GitHub App private key from Keycard Vault, mints a one-hour installation token scoped to the target repo with `contents:write` only, and clones.
3. Worker round: it gets a Keycard-signed token for the Anthropic resource, exchanges it at Anthropic Workload Identity Federation for a one-hour API token, and runs Claude Code in a container with that one secret, the clone as the only bind mount, a fixed tool allowlist, read-only root, non-root, capability-dropped and resource-limited. The agent commits on `factory/<task_id>`; it has no GitHub token. If nothing changed the run exits 3.
4. Judge round: it fetches the Codex key from Keycard Vault and runs Codex in a second container against a fresh clone of the worker's tree (mounted read-only), with `judge-prompt.md` as its only instructions. Codex reads the diff, runs the repo's checks, tries to refute the change, and ends with `VERDICT: VERIFIED | CAVEATS | REFUTED` and findings. Anything but VERIFIED goes back to the worker as a revision round, up to three rounds.
5. A push container pushes the branch with a fresh `contents:write` token. The host opens the PR, with the verdict and findings in the body, using a separate `pull_requests:write` token no container ever had, but only on VERIFIED or CAVEATS. REFUTED exits 5 and a missing verdict exits 6, branch pushed, no PR.
6. A ruleset on the target repo requires one human approval and green CI before merge. The App authors the PR, so it cannot approve it.

## Where things live

- The mini holds this repo as a clone of `main` and pulls after each merge. It never pushes. The only credential on it is the Keycard client id and secret, outside the repo. The Anthropic credential, the Codex key and the GitHub App key all come from Keycard per run.
- Changes to the factory itself land by pull request from a laptop, under the same ruleset as the target repos. `factory run` records the checkout's commit in the manifest and refuses to start on uncommitted changes.
- Keycard, Anthropic and GitHub App identifiers are constants at the top of `factory`. None of them is a secret.

## Running

```sh
docker build -t factory-sandbox .
FACTORY_SECRETS_DIR=~/factory-secrets ./factory run queue/<task>.json
./factory lint                                                # the queue against tasks.md; batch runs this first and refuses on problems (FACTORY_QUEUE=<dir> for another queue)
FACTORY_SECRETS_DIR=~/factory-secrets ./factory batch        # the overnight loop: each task bases on the previous task's branch; stops on the first failure; writes runs/batch-<timestamp>.md
FACTORY_SECRETS_DIR=~/factory-secrets ./factory batch --continue   # keep going past a failure, skipping only tasks that build on it
./factory report                                              # last 20 runs: exit, judge rounds, verdict, PR
./factory stop <run_id>
```

## Overnight

Write the night's tasks as numbered files (`010-…json`, `020-…json`) so they run in order. `factory batch` chains them: every task after a successful one bases on that task's `factory/<task_id>` branch (the task file is not modified; a temp copy carries the rewritten `base_branch`), so the morning brings a stack of judged PRs to review and merge bottom-up; the first failure stops the batch and leaves the rest queued. `--max-tasks N`, `--stop-at HH:MM` and `--no-chain` bound it. With `--continue` the batch goes on past a failure: the failed task's branch is still pushed as evidence, so every task that would build on it (by its own `base_branch`, or by the chain) is moved to `queue/failed/` unrun, and the chain resumes from the next task's own `base_branch`. A finished task file moves to `queue/done/` or `queue/failed/`, so a rerun never repeats it. Tell the worker in each task to commit `docs/BLOCKED-<task_id>.md` with the reason when it cannot finish, so a chain stops with evidence rather than a silent exit 3. Details in [`factory.md`](factory.md#batch-and-overnight-runs). For a new project make the first task the test harness and CI, so the judge has checks to run. Start the batch under `nohup` or in tmux, keep the mini awake, and read `factory report` with coffee. The factory never merges: one approval per PR is the gate.

`factory stop` kills the run's container, writes a `HALT` file that blocks further runs until a human removes it, and records the incident in the run log (and in the manifest when no live orchestrator will finalize it).

## History

The first version of this repository was a different design: a Linear-driven worker, a two-model judge and a merge gate in GitHub Actions. It was retired in favour of this one; the code is in the history before the `retire-v1` merge.
