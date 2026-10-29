# Factory

A personal software factory on an isolated Mac mini. Autonomous coding agents (Claude Code) pick up tasks and work on my own GitHub repos. Useful first. Follows the Keycard Software Factory reference architecture and Agent Baseline controls where that is reasonable for one user on one machine.

Reviewed against a second opinion on 2026-10-28. Changes from that review are marked `(review)`.

## Non-goals for v1

Egress proxy / enforced network allowlist, Temporal, Socket, OpenShell, Kubernetes, Linear intake, agent registry tooling, multi-tenant, more than one concurrent job.

## Trust boundary (review)

The **orchestrator** on the mini is the trust boundary, not the container. It reads the task, mints credentials, builds the `docker run` command from a fixed schema, and collects results. Nothing the agent writes or says can change image, mounts, flags, repo, or token scope. Task text, repo contents, and tool output are untrusted input.

## Components

### 1. Sandboxed execution

- One fresh Linux container per job (Docker Desktop or OrbStack). On macOS that is a Linux VM, so the boundary is the VM plus the container, which is stronger than Docker on a Linux host.
- Only the cloned repo is mounted, as the writable workdir. Read-only root FS. Non-root user. No Docker socket, no host home, no host network.
- Image pinned by digest. Limits: `--memory 4g --cpus 2 --pids-limit 512`, wall-clock timeout 60 min, orphan cleanup on orchestrator start. (review)
- Container is removed after the job. Artifacts are the pushed branch, the run manifest, and the run log.

### 2. No static secrets in the sandbox

- Two secrets exist per run, both short-lived and both delivered as 0400 files on a tmpfs mount, never as `docker run` arguments: (review)
  - `github_token`: a GitHub App installation token scoped to the one target repo with `contents:write` and `pull_requests:write` only. The orchestrator mints it per run: it fetches the App's private key from Keycard Vault (resource `urn:factory:github-app-key`, a dependency of the orchestrator Application, policy-checked and audited like the Anthropic resource), signs a 10-minute app JWT in memory, and calls `POST /app/installations/<id>/access_tokens` with the repo and the two permissions. The key is not stored on the mini. Keycard has no GitHub App connector, so repo scoping happens in the orchestrator's minting call, not in Keycard.
  - `anthropic_token`: the Claude Code credential, issued per run with no API key anywhere. The orchestrator authenticates to the software factory zone as its own Application (`urn:factory:mini`) and gets a one-hour Keycard-signed OIDC token for the `https://api.anthropic.com` resource, policy-checked and audited. It exchanges that at Anthropic's Workload Identity Federation endpoint for a one-hour bearer token bound to the `factory` workspace and the `factory-mini` service account. The container uses it as `ANTHROPIC_AUTH_TOKEN`.
- No PAT, no `gh auth` cache, no `.claude` auth in the image. TTL equals the job timeout.
- Known limit: a token copied out during the run stays valid until it expires or is revoked. The run log and manifest redact both tokens.

### 3. Intake and task binding

- One intake for v1: a task file in `queue/` on the mini, written by me, readable but not writable by the container. (review)
- Job schema: `{repo, base_branch, task_id, instructions}`. The orchestrator validates it and derives everything else. The agent never sees or edits the job file.
- Keycard zone policy grants the run authority for that repo only.

### 4. Run manifest and log (review)

- `runs/<run_id>/manifest.json`: job hash, repo, base commit SHA, image digest, model and Claude Code version, Keycard grant id, start/end time, final commit SHA, PR URL, exit status.
- `runs/<run_id>/log.jsonl`: one line per tool call and per token issue, with run id, timestamp, tool, redacted arguments, exit status. Written by the orchestrator from the agent's stream, so the agent cannot rewrite it.
- Keycard zone audit covers the authorization side.

### 5. Human gate on merge

- Agent pushes `factory/<task_id>` and opens a PR. CI runs. I merge.
- Enforced in GitHub, not by instruction: branch protection on `main`, required checks, the App has no merge or admin permission, and PRs from the bot do not get Actions secrets. (review)

### 6. Kill switch

- One script, `factory stop <run_id>`: stops the container, blocks new dispatch, revokes the Keycard grant and the GitHub token, and appends an incident line to the manifest. (review)
- Known limit: revocation does not undo work already pushed. The PR gate catches that.

## Flow

```
task file in queue/
  -> orchestrator validates job, creates run_id, writes manifest
  -> orchestrator mints repo-scoped GitHub token from the App, fetches Claude credential from Keycard
  -> both piped into the container, land as 0400 files on tmpfs
  -> docker run (pinned image, repo mount, secrets mount, limits)
  -> agent works; orchestrator streams tool calls to log.jsonl
  -> agent pushes branch, opens PR
  -> container removed, manifest finalized
  -> human reviews and merges
```

## Agent Baseline mapping

Status is Implemented, Partial, or Planned. Each has a check that proves it. (review)

| Control | Status | What proves it |
|---|---|---|
| CON-03 Isolated execution | Partial | `docker inspect` shows only the repo mount, non-root, read-only FS, limits. Egress is open, so not a boundary against exfiltration. |
| CON-04 Capability profile | Partial | One profile: the Dockerfile, the run flags, and the agent tool allowlist in the entrypoint. Not centrally governed. |
| AUT-01 Identity and attribution | Implemented | Manifest links run_id, task_id, repo, grant id, commit SHA. |
| AUT-02 Task-bound authority | Partial | Token scoped to one repo. Not scoped to the task beyond that. |
| AUT-04 Just-in-time credentials | Implemented | Tokens issued per run, file-delivered, TTL = timeout. Image has no secrets. |
| AUT-05 Independent approval | Implemented | Ruleset on `main` in each target repo: PR required, 1 approval, stale approvals dismissed, `test` check required, no App in the bypass list. The App authors the PR so it cannot approve it. |
| AUT-06 Fail-closed | Implemented | Orchestrator refuses to start a run on any token or schema failure. |
| OBS-01 / OBS-02 Telemetry and correlation | Partial | Log and manifest keyed by run_id. No integrity protection on the files. |
| VAL-03 Artifact testing | Implemented | Required CI checks on the PR. |
| RES-01 Stop and revoke | Partial | `factory stop` exists. Token-copy limit documented. |
| RES-03 Evidence preservation | Partial | Manifest and log kept per run. No retention policy. |
| Discover, Validate (other), RES-02, RES-05 | Planned | Not in v1. |

## Accepted risks for v1

- Open egress from the container. The agent can exfiltrate the repo and the two tokens over HTTPS. Revisit with the Keycard egress proxy when agents run in a cluster or when this matters.
- Single machine, single user, no evidence integrity.

## Files

- `factory.md`: this spec.
- `Dockerfile`: the sandbox image.
- `factory`: orchestrator script (`run`, `stop`).
- `queue/`, `runs/`: task intake and per-run evidence. Not in the image.

## Implementation notes (mini, 2026-10-29)

- **Image:** base `node:22-bookworm-slim@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da`, pinned in the Dockerfile. Built 2026-10-29; local image id `sha256:2519c54f4f1f24ca2712ea5f8703877d1df8cdd9e4f93445a08439d5bd27ffaa` (Claude Code 2.1.312, gh 2.103.3). `factory run` records the id that `factory-sandbox` resolves to and runs the container by that id, so the manifest names exactly what ran. A rebuild changes the id; update it here.
- **Docker CLI:** Docker Desktop keeps its CLI inside the app bundle unless the `/usr/local/bin` symlinks are installed. `factory` adds `/Applications/Docker.app/Contents/Resources/bin` to `PATH` when `docker` is not found. Docker Desktop must be running.
- **Dockerfile vs. the reviewed draft:** `userdel -r node` before `useradd` (the base image already has uid 1000); the entrypoint sets `HOME=/tmp` because the root FS is read-only, so the `--tmpfs /home/agent/.claude` run flag was dropped; `safe.directory /work` was kept but is not needed, since Docker Desktop shows bind mounts as owned by the container user; `--verbose` is required with `-p --output-format stream-json` in Claude Code 2.1; `claude` reads stdin from `/dev/null` so the secrets pipe never reaches it.
- **Secrets delivery:** the orchestrator pipes both tokens to the container's stdin, one per line, and the entrypoint writes them as 0400 files on a 64 KB tmpfs at `/run/secrets`. They never touch the host filesystem, `docker run` arguments, host-set env, or `docker inspect` output (checked). The only host copy is the source files in `$FACTORY_SECRETS_DIR`. A host RAM disk under `/Volumes` was tried first and dropped: the Docker Desktop VM does not see volumes mounted after it started, so the bind mount failed on every run but the first.
- **Log:** every stdout/stderr line from the container becomes `{run_id, ts, event}`, where `event` is the parsed stream-json object or `{type:"text", text}` for anything else, after both token values are replaced with `[REDACTED]`. Factory-side events (clone, secrets issued, exit) use `type:"factory"`.
- **Locks:** `.lock/` (directory, atomic mkdir) is the one-job-at-a-time lock and is removed when the run exits. `HALT` is written by `factory stop` and blocks `factory run` until a human deletes it.
- **GitHub App (2026-10-29):** App `kmaida-software-factory` (PR author `kmaida-software-factory[bot]`; was `kmaida-factory-bot` for PR 29), client id `Iv23liCLESgW74Wn2Ie2`, installation `176545264`, both constants in `factory`. The private key is a Keycard Vault API Token credential (the PEM base64-encoded on one line; the orchestrator decodes it and hands it to LibreSSL through a process substitution, so it never touches disk). `mint_github_token` passes the JWT to curl through a config on stdin. Fetching the key failed until the resource was added as a dependency of the Application. Tested 2026-10-29 with the Keycard team: the first permits were written with identifiers in the Cedar entity slots (`Keycard::Resource::"urn:…"`), which never match, so only the dependency plus the copied `default-app-direct-access` rule was allowing. Both `factory-orchestrator-*` permits now use `principal is Keycard::Application` with `principal.identifier` and `resource.identifier` in the `when` block, which allows on its own with no dependency. The dependencies are kept as the Application's declared manifest; the permits are the versioned, testable authority, and a `forbid` on the Application overrides both. The host clone uses the same token through a one-shot credential helper so private repos work. Revocation from `factory stop` is not possible because the orchestrator does not keep the token; it expires within 60 minutes.
- **Keycard and Anthropic federation (2026-10-29):** `factory run` authenticates to the zone in `KEYCARD_ZONE` with `grant_type=client_credentials` using `keycard_client_id` and `keycard_client_secret` from `$FACTORY_SECRETS_DIR` (the Application's Client ID & Secret, passed to curl via a config on stdin, not argv) and `resource=https://api.anthropic.com`. The Anthropic resource uses the Zone Provider with a 1h lifetime, so Keycard returns a signed JWT (`sub` = `urn:factory:mini`, `aud` = the resource). The orchestrator posts it to `https://api.anthropic.com/v1/oauth/token` as a `jwt-bearer` assertion with the federation rule, organization, service account and workspace ids (constants in `factory`, none secret) and gets a `sk-ant-oat…` bearer token, scope `workspace:developer`, 3600 s. The run refuses to start if either step fails. Policy: the `software-factory-policies` set, a permit for the orchestrator Application on the Anthropic resource. Evidence: the `credentials:issue` audit event in the zone and the authentication event under Keys & access → Workload identity in the Claude Console; the manifest records `keycard_zone`. A vaulted API key in Keycard was used for one day before federation was set up and has been removed from the resource.
- **Agent capability profile:** `claude` runs with an explicit `--allowedTools` list (Bash, Read, Edit, MultiEdit, Write, Glob, Grep, NotebookEdit, TodoWrite, Agent). Those run without prompts, since nobody is there to answer one; any other tool is denied. `--permission-mode acceptEdits` was tried first and blocked every Bash call, including `git commit`, so the agent could not finish. The container, the token scope and the PR gate are the boundary, not Claude's prompts. The entrypoint commits anything the agent leaves uncommitted before pushing. If the branch then has no commits beyond the base (the agent declined or produced nothing), it pushes nothing and exits 3, so no empty branch appears on GitHub; verified 2026-10-29 in a container against a local bare repo for both the declined and the changed case.
- **The factory's own definition is versioned and pulled, never pushed from the mini (2026-10-29):** this folder is a clone of `kmaida/software-factory`, and `main` there moves only by reviewed PR under the same ruleset as the target repos. The mini holds no credential for that repo; it pulls over HTTPS. `factory run` records the checkout's commit as `factory_commit` in the manifest beside `image_digest`, and refuses to start when the checkout has uncommitted changes (`FACTORY_ALLOW_DIRTY=1` permits a development run and marks the commit `-dirty`). Changes made on the mini go out as a patch that Kim commits from the laptop, or as a factory task against the factory repo itself. `runs/`, `queue/*.json`, `.lock` and `HALT` are host state and gitignored. Reasoning: agentbaseline.org's reference architecture treats the agent host as untrusted with no credentials, and a write key on the mini would let the host that runs the agents rewrite and publish its own profile.
- **Not in the manifest yet:** model and Claude Code version.
- **Federation verified 2026-10-29:** by hand (Keycard token → Anthropic exchange → one Messages call) and in a sandbox run, where Claude Code accepted the bearer token through `ANTHROPIC_AUTH_TOKEN`, edited and committed.
- **Vault key path verified 2026-10-29:** `factory-vault-002` against `kmaida/plan-my-today` opened PR 30 with the App key fetched from Keycard, exit 0. The `github_app.pem` file was then deleted from the mini. An earlier attempt (`factory-vault-001`) targeted text that only exists on the unmerged PR 29 branch; the agent changed nothing, pushed an empty `factory/factory-vault-001` branch and `gh pr create` failed. Lesson: a task must be doable against `base_branch` as it is, and an agent with nothing to do asks a question nobody answers. That empty branch is still on GitHub and should be deleted.
- **First real run, 2026-10-29:** `factory-hello-001` against `kmaida/plan-my-today`: minted token, cloned, agent session, commit, push of `factory/factory-hello-001`, PR opened by the App, exit 0, run time 19 s, agent cost about $0.07. Evidence in `runs/20261029T135537Z-factory-hello-001/`.
- **Verified end to end on 2026-10-29 with a Keycard-brokered Claude credential:** the agent ran a real session in the sandbox, edited and committed on `factory/<task_id>`, and the log redacted both tokens. Push and PR still fail in the dry run because the throwaway remote is a host path the container cannot reach; those need the GitHub App.
- **Verified in a real container on 2026-10-29:** `docker inspect` shows user `agent` (uid 1000), read-only root FS, `CapDrop=[ALL]`, `no-new-privileges`, 4 GiB memory, 2 CPUs, 512 pids, and only the `/work` bind mount plus the `/tmp` and `/run/secrets` tmpfs; no Docker socket; writes to `/` and `/usr` fail. The dry run clones, creates `factory/<task_id>` from `origin/<base>`, writes git config under `/tmp`, reaches `claude`, and exits 1 with "Invalid API key" on a dummy token; the log has zero token hits; lock, clone dir, and container are gone afterwards. `factory stop` writes `HALT` and the incident, and `factory run` refuses while `HALT` exists. Still untested: push, PR creation, the 60-minute watchdog, and a real Claude session (needs real credentials).
- **Known:** Docker's default `/tmp` tmpfs is `noexec`. Revisit if Claude Code needs to execute something from `/tmp`.

## TODO (Kim)

- Put the plan-my-today ruleset on `kmaida/software-factory` too (PR required, 1 approval, admin bypass for PRs only; no required check until the repo has CI). Decide what to do with the old design's `scripts/`, `skills/`, `templates/` and README there.
- Install the App on each further target repo (same installation; Settings → Applications → Configure → add repos).
- Decide what happens to a task file in `queue/` after its run; today it stays there and a second `factory run` of the same file starts a new run with a new run_id.
- `kmaida/plan-my-today` ruleset done 2026-10-29 (PR required, 1 approval, `test` required, bypass = repository admin for pull requests only). A legacy branch-protection rule on `main` still exists beside it; review it under Settings → Branches and delete it if redundant. Repeat the ruleset for each further target repo.
- Old factory experiment on `kmaida/plan-my-today` retired 2026-10-29: `factory-merge` and `factory-judge` workflows, `.factory/`, old merge App and its secrets removed; `CLAUDE.md` Factory rules rewritten for this factory; Dependabot now watches root npm (grouped minor/patch) and GitHub Actions.
