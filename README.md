# software-factory

A personal software factory on an isolated Mac mini. A task file names a repo, a base branch and instructions; the orchestrator runs Claude Code in a locked-down container against a fresh clone and opens a pull request that a human must approve. The spec, the design decisions and the current state are in [`factory.md`](factory.md).

## Layout

- `factory` — the orchestrator (bash 3.2, macOS). `factory run <task-file>` and `factory stop <run_id>`.
- `Dockerfile` — the sandbox image: Node, git, Claude Code, Codex (pinned), non-root user. One entrypoint, three modes (`work`, `judge`, `push`), each run as its own container with exactly one secret over stdin. No `gh`: the push token can only push.
- `judge-prompt.md` — what the Codex judge is told. Lives here, not in the target repo, so the worker cannot rewrite it.
- `test-factory.sh` — stubbed `docker`/`curl` check of the worker → judge → push loop.
- `factory.md` — spec, Agent Baseline mapping, implementation notes, TODO.
- `queue/` — task files, one JSON object each: `repo`, `base_branch`, `task_id`, `instructions`. Host state, not committed.
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
./factory stop <run_id>
```

`factory stop` kills the run's container, writes a `HALT` file that blocks further runs until a human removes it, and records the incident in the run log (and in the manifest when no live orchestrator will finalize it).

## History

The first version of this repository was a different design: a Linear-driven worker, a two-model judge and a merge gate in GitHub Actions. It was retired in favour of this one; the code is in the history before the `retire-v1` merge.
