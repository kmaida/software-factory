# Review brief: factory v2 (built 2026-10-28/29)

You are reviewing a from-scratch rewrite of a personal "software factory": an orchestrator on a Mac mini that takes a task file, runs Claude Code inside a locked-down Docker container against a clone of a GitHub repo, and opens a pull request that a human must approve. It replaces the previous factory in this repository (Linear-driven worker, two-model judge, merge gate in CI). None of the old code is reused.

## What to read, in order

1. `factory.md` — the spec the implementation was built to, followed by `## Implementation notes` (what was actually done, with the deviations and why) and `## TODO (Kim)`.
2. `Dockerfile` — the sandbox image and its entrypoint (reads two secrets from stdin, configures git, runs `claude -p`, commits, pushes, opens the PR; refuses to push an empty branch).
3. `factory` — the orchestrator (bash 3.2, macOS). `run <task.json>` and `stop <run_id>`.
4. `queue/*.json` — example task files. `runs/*/manifest.json` and `log.jsonl` — evidence from real runs today, including one where the agent declined the task.

## Trust boundaries and design decisions to scrutinize

- No long-lived credentials on the host except a Keycard client id and secret (0400 files outside the factory dir). Per run, the orchestrator gets a Keycard-signed JWT for `https://api.anthropic.com`, exchanges it at Anthropic Workload Identity Federation for a 1h bearer token, and separately fetches the GitHub App private key from Keycard Vault to mint a 1h installation token scoped to the one target repo with contents:write and pull_requests:write only.
- Secrets reach the container only over stdin, written to a tmpfs at `/run/secrets` as 0400; the only bind mount is the clone at `/work`. Container flags: `--read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --memory 4g --cpus 2 --pids-limit 512`, non-root uid 1000.
- Claude Code runs with an explicit `--allowedTools` list and no permission prompts; the container, the token scope and the PR gate are the boundary, not Claude's prompts. `--dangerously-skip-permissions` was deliberately not used.
- The orchestrator redacts both tokens from the log stream by string replacement before writing `log.jsonl`.
- Merge gate is a GitHub ruleset on the target repo: PR required, 1 approval, required `test` check, no force push, bypass only for repo admins and only for pull requests.
- Watchdog: `docker stop` after `TIMEOUT_SEC`; `stop` writes a `HALT` file and prints revocation TODOs rather than revoking tokens automatically.

## Questions I want answered

1. Can the agent inside the container exfiltrate either token, or use the GitHub token for anything beyond pushing `factory/<task>` and opening a PR on the one repo? Look at the credential helper, `gh` config, the git remote, and what the entrypoint exports.
2. Is the redaction sufficient? Where could a token appear in output in a form the string replacement misses (base64, URL-encoded, split across lines)?
3. The orchestrator uses `curl -K -` with config on stdin and `openssl dgst -sign <(...)` to keep secrets off the command line. Are there remaining places where a secret lands in argv, the environment of a child, or a file outside tmpfs?
4. Failure modes: what happens on a crash between clone and manifest finalization, on a second run of the same task id, on a stale lock, on `docker stop` racing the final commit?
5. Anything in `factory.md`'s spec that the implementation silently does not meet.
6. Bash 3.2 and macOS portability traps.

## Known gaps (don't spend time re-finding these)

- Task files stay in `queue/` after a run; nothing moves them.
- `stop` does not revoke the Anthropic or GitHub tokens; they expire within an hour.
- No egress control beyond what the container's missing capabilities give; the agent has full network.
- Run logs are host files, not tamper-evident.
- The empty-branch guard in the entrypoint was verified against a local bare repo in a container, not yet on a real GitHub run.

Report findings ranked by severity, each with the file and line and a concrete failure scenario. Ignore style.
