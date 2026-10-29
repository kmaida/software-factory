# software-factory

A personal software factory on an isolated Mac mini. A task file names a repo, a base branch and instructions; the orchestrator runs Claude Code in a locked-down container against a fresh clone and opens a pull request that a human must approve. The spec, the design decisions and the current state are in [`factory.md`](factory.md).

## Layout

- `factory` — the orchestrator (bash 3.2, macOS). `factory run <task-file>` and `factory stop <run_id>`.
- `Dockerfile` — the sandbox image: Node, git, gh, Claude Code, non-root user, entrypoint that takes secrets over stdin and ends by pushing a `factory/<task_id>` branch and opening the PR.
- `factory.md` — spec, Agent Baseline mapping, implementation notes, TODO.
- `queue/` — task files, one JSON object each: `repo`, `base_branch`, `task_id`, `instructions`. Host state, not committed.
- `runs/<run_id>/` — per-run evidence: `manifest.json` and `log.jsonl`. Host state, not committed.

## How a run works

1. The orchestrator validates the task file, takes a lock, and writes a manifest naming the run, the task, the base commit, the image digest and its own commit.
2. It gets a Keycard-signed token for the Anthropic resource and exchanges it at Anthropic Workload Identity Federation for a one-hour API token. It fetches the GitHub App private key from Keycard Vault and mints a one-hour installation token scoped to the target repo.
3. Both tokens go into the container over stdin and land as 0400 files on a tmpfs. The clone is the only bind mount. The container is read-only, non-root, capability-dropped and resource-limited.
4. Claude Code works with a fixed tool allowlist. The orchestrator streams its output to the run log with both tokens redacted.
5. The entrypoint commits, pushes the branch and opens the PR. If nothing changed it pushes nothing and exits 3.
6. A ruleset on the target repo requires one human approval and green CI before merge. The App authors the PR, so it cannot approve it.

## Where things live

- The mini holds this repo as a clone of `main` and pulls after each merge. It never pushes. The only credential on it is the Keycard client id and secret, outside the repo.
- Changes to the factory itself land by pull request from a laptop, under the same ruleset as the target repos. `factory run` records the checkout's commit in the manifest and refuses to start on uncommitted changes.
- Keycard, Anthropic and GitHub App identifiers are constants at the top of `factory`. None of them is a secret.

## Running

```sh
docker build -t factory-sandbox .
FACTORY_SECRETS_DIR=~/factory-secrets ./factory run queue/<task>.json
./factory stop <run_id>
```

`factory stop` kills the container, writes a `HALT` file that blocks further runs until a human removes it, and records the incident in the manifest.

## History

The first version of this repository was a different design: a Linear-driven worker, a two-model judge and a merge gate in GitHub Actions. It was retired in favour of this one; the code is in the history before the `retire-v1` merge.
