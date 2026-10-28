# Software factory: what we built and how it follows the agentbaseline reference architecture

Author: Kim Maida, with Claude Code (Fable 5.1)
Last updated: Oct 26, 2026
Status: Phase 1, running on one repo (plan-my-today). Phase 2 (auto-merge) gated on metrics. Phase 3 (Mac mini + egress proxy) waiting on hardware.

Purpose of this doc: a record of what we built in one day, how each piece lines up with the [agentbaseline software factory reference architecture](https://agentbaseline.org/reference-architecture), and the parts that broke on the way. Raw material for a demo, a blog post, or a video later. The plugin itself lives in this repo; the plan that produced it is in `~/.claude/plans/i-do-a-lot-lucky-micali.md`.

## 🎯 Why

I run a lot of dogfood projects and I'm the bottleneck on all of them. The goal was a loop where I write the task and merge the result, and nothing in between waits on me. Keycard co-authored the reference architecture, so the second goal was to build the loop the way that document says to, and find out where the document and the product disagree with reality.

Open questions as of today:

- Does the two-model judge catch anything the deterministic gate doesn't? We have zero data; the first real verdicts land on the next issue.
- Is `auto` permission mode too restrictive for workers, or is the classifier the right interim egress control? One run so far, and it passed.
- How many repos before per-repo secrets get annoying enough to want an org?

## 🏭 What we built

Shape: a queue in front, two independent reviewers behind, a deterministic merge gate in CI, and me only at intake and merge. Agents implement and critique; scripts and CI decide. All durable state lives in Linear and GitHub, never in a session.

| Piece | What it is | Where it runs |
|---|---|---|
| Queue | Linear issues in a registered project with the `factory` label and a `## Done when` section | Linear (team KIM) |
| Dispatch | One idempotent sweep: claim an issue, start a worker, turn judge verdicts into Linear transitions, reset stale runs | `claude -p "/factory:factory-dispatch"` on my laptop, later a LaunchAgent on the mini |
| Worker | Implements one issue with `/fable-loop` in its own git worktree, opens a PR with the real check output, exits | `claude -p` under `keycard agent exec`, `auto` permission mode, 80 turns / 90 minutes |
| Judge | Claude and Codex each try to refute the PR at its exact head SHA; both post a commit status | GitHub Actions, three isolated jobs |
| Merge controller | Runs `risk-gate.sh` from the PR's base commit and merges only `low`-risk PRs with its own App token | GitHub Actions |
| Policy | `.factory/policy.json`: allow and deny paths, size cap, allowed check commands, env for checks, the `auto_merge` switch | Each repo, read from the base commit so a PR can't edit its own rules |
| Credentials | One GitHub App brokered by Keycard into local processes as `GH_TOKEN` | Keycard zone `1jgewf…` |

Repo for the plugin: `~/Development/software-factory`. Four skills, three scripts, two workflow templates. The risk gate has a nine-case self-check; nothing else has tests yet.

## 🔁 One issue's life (KIM-569, the first run)

1. I wrote KIM-569: add an "Autonomous changes" section to the README. Done when: `npm test`.
2. Dispatch claimed it (status In Progress, comment `factory: run <id>`), created the worktree `plan-my-today-factory-KIM-569`, and started the worker.
3. The worker read the issue, made a four-line README change, ran `npm test` (792 passing), opened [PR #7](https://github.com/kmaida/plan-my-today/pull/7) with two stated assumptions and the check output, and moved the issue to In Review.
4. CI passed, and the judge refuted the PR wrongly because its check job had none of the env vars the repo's own CI sets (bug 6 below).
5. I reviewed the diff and merged. Phase 1 means I merge everything.
6. The next sweep saw the merge, commented `factory: merged <url>`, and the issue went to Done.

Human touches: writing the issue, reading a four-line diff, clicking merge.

## 🗺️ Mapping to the reference architecture

The reference names components and four boundaries, then defines three autonomy levels. We're Level 1 with a couple of Level 2 traits. Status column: Done, Partial, Phase 3.

| Reference component | Ours | Status |
|---|---|---|
| Profile (versioned context, tools, rules, access) | `.factory/policy.json` + CLAUDE.md snippet + `worker-settings.json`, all in git, read from the base commit | Done (not authenticated; that's a Level 2 requirement) |
| Approval policy ("automatic approval is an option, never a requirement") | `auto_merge: false`; I merge. Phase 2 flips it per repo after 10 merges with 0 reverts | Done |
| Runtime authorization service (agents never decide their own access) | Policy from base; `.factory/`, `.github/`, `.claude/`, CLAUDE.md changes force human review; Keycard decides what the worker can hold | Done |
| Execution layer (starts agents, retries, stops, kills on demand) | Dispatch skill with a state table; `FACTORY_PAUSED` repo variable stops merges and dispatch; kill = close the process | Done |
| Egress proxy (attaches credentials; agent never holds them) | Keycard brokers `GH_TOKEN` into the process. For the worker's shell commands, Claude Code's sandbox refuses hosts outside `worker-settings.json` under `auto` mode | Partial (a real default-deny proxy outside the agent is Phase 3) |
| Supply chain firewall | Workers can't touch lockfiles or manifests at all (policy deny). Judge CLIs pinned by version | Partial (no admission point or cooldown for packages) |
| Model gateway | None; Claude Code and Codex talk to their providers directly | Phase 3 |
| Tamper-evident record linked by run id | Keycard audit log + GitHub statuses + Actions logs + Linear comments share one run id. `~/.factory/logs` is agent-writable | Partial |
| Monitoring agent (Level 3) | None; `scripts/stats.sh` counts merges and reverts by hand | Not started |

### Boundary 1: sandbox

The worker runs inside Claude Code's seatbelt sandbox on my laptop. Writes are confined to the worktree and temp dirs, and protected paths like `.claude/` and shell rc files stay read-only. That's a developer-machine sandbox, which the reference allows at Level 1, and it is not a microVM the agent can't escape. The judge is the stronger case: PR code runs in a GitHub Actions job with `permissions: {}` and no secrets, on a runner that's destroyed afterward, and the two model jobs and the status-posting job each get a fresh runner.

### Boundary 2: network

Default-deny isn't there yet. What is there: Claude Code's sandbox proxy refuses hosts outside the allowlist unless the command names them and the classifier approves, and cloud metadata endpoints and the npm registry are on the deny list (a worker's `npm install` from the registry or its common mirrors fails at connect; dispatch installs `node_modules` from the base lockfile with `--ignore-scripts` before the worker starts). The Keycard egress proxy on the mini is the Phase 3 answer, and it closes this boundary and the sandbox one together.

### Boundary 3: supply chain

Two cheap controls do most of the work for now. Workers can't change the root `package.json` or lockfile, so a worker PR can't introduce a dependency; the gate forces review if it tries (a nested `src/package.json` matches the allow list, which changes module type for that directory but not what the root lockfile installs). Workers can't fetch one from the registry either: it and its common mirrors are denied to the worker process, so the one-command path to running third-party code is closed except for packages already in the worker's npm cache (git and tarball URLs on allowed hosts, and deliberate download-and-execute, are not closed). The judge installs pinned versions of both CLIs so an upstream release can't change verdict behavior unannounced. We don't verify images or attach SBOMs.

### Boundary 4: identity and access

This is the boundary Keycard is for, and it's where the document and the product disagreed with each other the most. Details in the next section. Net result: every local factory process acts as me, through one brokered GitHub credential it never sees on disk; anything that could forge an approval or merge runs where no local process has the token.

## 🔑 What Keycard does here, and three things I had to learn

Keycard brokers the GitHub credential into the worker and dispatcher (`keycard agent exec --config keycard.toml -- claude -p ...`). Nothing is cached by the factory, every exchange is on my behalf in the zone audit log, and `agent exec` fails hard when consent is missing instead of hanging an unattended run. The denial test passed on the first try: the brokered token can push a branch and open a PR, and gets a 403 when it tries to post a `factory/judge-*` status.

Three facts shaped the design, none of which I knew in the morning:

1. On the CLI path, the Keycard principal is always the Keycard CLI application plus the signed-in user. A `keycard.toml` picks resources, not an identity. So "one Keycard application per role, enforced by Cedar" was never available; I'd planned three role configs and they collapsed to one.
2. A zone has one provider per issuer. One GitHub App backs every GitHub resource in the zone, so "one GitHub App per role" collapsed too. Role separation now comes from where code runs: statuses are posted from CI with the workflow's own token, `FACTORY_APP_PRIVATE_KEY` lives only in Actions secrets, and local processes get the one worker-level token.
3. A GitHub App used as a Keycard provider needs the Account permission "Email addresses: read-only". Without it, every authorize naming a GitHub resource dies with `server_error` right after consent, before GitHub is ever shown. Two clients failed identically, the management API said everything was configured correctly, and the zone's event feed had no row for the attempt. A colleague found it. The svc-sts source agrees: the GitHub provider builds the user's identity from `/user/emails`.

All three are now in the using-keycard skill's field notes so the next project doesn't pay for them again.

## 🧪 What broke on day one

Every one of these came from a review or a real run, and every one is fixed. Keeping the list because it's the honest part of the story.

| # | Found by | Defect | Fix |
|---|---|---|---|
| 1 | Codex review of the plan | Judge verdicts weren't tied to the merged SHA | Verdicts are commit statuses on the exact SHA; a push blanks them |
| 2 | Codex review of the plan | The PR could edit its own risk policy | Policy and gate script are read from the PR's base commit |
| 3 | Codex review of the plan | "Judge can merge but not push" isn't expressible in GitHub permissions | Merge moved into a CI job with its own App token; no agent holds merge rights |
| 4 | Security scan of the first commit | Gate verdict parsed from text; untrusted output interpolated into shell | Verdict from exit code; every value passed through env vars; `pull_request_target` |
| 5 | Codex review of the plugin | `jq '// true'` turned `auto_merge: false` into `true` | Explicit `== true` check, plus a self-check case |
| 6 | First real judge run | Judge ran `npm test` with no env; refuted a correct PR | `check_env` and `check_setup` in policy, applied from base |
| 7 | First real run | `factory-merge.yml` had `: ` inside a plain `run:` scalar; GitHub rejected the file | Block scalar |
| 8 | First real run | GitHub `factory` label didn't exist; `gh pr create --label` dropped it silently | Onboarding creates the label |
| 9 | First sweep | Dispatcher under `auto` mode can't spawn workers or change Linear state | Dispatcher runs with `bypassPermissions`; workers stay on `auto` |
| 10 | Security scan | Git reset before the second model restored the stripped agent config | Strip again after the reset |
| 11 | Security scan | PR code and secrets in one judge job | Three jobs on fresh runners; verdicts as job outputs; fail closed |
| 12 | Ponytail pass | Fencing tokens, heartbeats, per-judge environments, dollar budgets, a second pause mechanism | Deleted; one-person scale |
| 13 | Codex review of the baseline plan | Every factory secret was a repository secret; a worker PR adding one workflow file could print the merge App key and both model keys | All secrets in a default-branch-only GitHub Environment; repository copies deleted; keys rotated |
| 14 | Codex review of the baseline plan | The gate accepted `factory/judge-*` statuses by context name; a PR-added workflow with `statuses: write` could forge them | Judge signs VERIFIED with an HMAC key only a default-branch run can read; the merge gate recomputes it |
| 15 | Codex review of the baseline plan | The merge gate ran `.factory/risk-gate.sh` from whatever base the PR named; a PR author can retarget the base | Gate refuses any PR not based on the default branch before reading from it |
| 16 | Codex review of the baseline plan | The judge workflow ran on `pull_request`, so a PR could rewrite the workflow that judges it; PR code on the runner could poison the base branch's cache | `pull_request_target`; PR code only in throwaway containers, no network during checks |

The pattern across the list: every "security" defect was a trust-boundary mistake (who holds which token, which commit a rule is read from), and every "it doesn't work" defect was an environment assumption that held on my laptop and nowhere else.

## 📊 Phase gates

| Phase | Entry condition | What changes |
|---|---|---|
| 1 (now) | Plugin built, one repo onboarded | I merge everything. Judge and gate run and comment. |
| 2 | 10 factory merges, 0 reverts, 0 gate false-lows on that repo | `auto_merge: true` in that repo's policy; merge App installed; `main` restricted to the merge App |
| 3 | Mac mini arrives | Dedicated `factory` macOS user, LaunchAgent dispatch every 30 min, Tailscale for access, Keycard egress proxy around the worker |

`scripts/stats.sh <owner/repo>` prints the two numbers that gate Phase 2.

## 📝 Demo and content angles

- [ ] Live demo: write a Linear issue, run one sweep, watch the PR, the two judge statuses, and the gate comment appear.
- [ ] Blog: "what the reference architecture asks for vs. what one person can build in a day," using the mapping table above.
- [ ] Blog or short video: the three Keycard gotchas, especially the email-permission one, because the failure mode looks exactly like a platform bug.
- [ ] Blog: the day-one defect list as a case for cross-model review and automated security scanning of agent-written infrastructure.
- [ ] Follow-up once Phase 2 is on: did auto-merge ever merge something I'd have rejected?
