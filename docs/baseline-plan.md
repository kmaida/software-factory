# Closing the gaps against the agentbaseline.org reference architecture

Status: plan, 2026-10-27, revision 9. A0 landed 2026-10-27 (PR 14) and A1 on 2026-10-28; A2 through A8 are not implemented. Revisions 1 through 7 were refuted by Codex; revision 8 came back CAVEATS with two wording fixes, applied here without another pass. The findings and what changed are at the end.

**Headline, found in revision 7:** today, before any of this plan, a worker PR that adds a workflow file can read `FACTORY_APP_PRIVATE_KEY`, `ANTHROPIC_API_KEY`, and `OPENAI_API_KEY`, because they are repository secrets and same-repo `pull_request` workflows receive repository secrets. The worker skill's "never edit `.github/`" is prose. A0 fixes this first; nothing else in Phase A matters until it lands.

The reference (https://agentbaseline.org/reference-architecture) names four boundaries that must be enforced outside the agent's loop: sandbox, network, supply chain, identity and access. Plus a tamper-evident record linked by run, and a profile that is "the most the agent can ever do." `docs/writeup.md` has the current mapping. This doc is the delta: what narrows each boundary, what that costs, what it does not close, and what has to wait.

Two honesty rules, from the Codex reviews:
- "Done when" is an adversarial test. If the check can pass while the control is absent, it is not a check.
- Every item names its residual: the bypass that remains after it lands. An item with no residual is a claim, not a control.

One fact that shapes every residual below: **dispatch and the worker are the same uid (502) and the same Keycard principal, so they hold the same `GH_TOKEN` and the same `LINEAR_TOKEN`.** Nothing one of them writes is independent of the other. The independent writers today are GitHub Actions (its own token, statuses and logs), the merge App (its own key), and Keycard's audit log. Phase A works within that; Phase B's broker is what changes it.

## Where we stand

| Boundary | Enforced by today | Gap |
|---|---|---|
| 1 Sandbox | Worker: Claude Code seatbelt, non-admin `softwarefactory` user on the mini. Judge: ephemeral Actions runner, `permissions: {}`, no secrets in the job that runs PR code. | Worker sandbox is a developer-machine sandbox, not one the agent can't escape. |
| 2 Network | `worker-settings.json` allowlist + `auto` classifier, inside the agent. Keycard brokers tokens in. Metadata IPs and the npm registry denied; dispatch installs `node_modules` from the committed lockfile with `--ignore-scripts` before the worker starts (A1). No MCP servers. | Not default-deny, and the control lives inside the agent process. |
| 3 Supply chain | Policy denies manifests and lockfiles at merge. Judge workflow and prompt come from base and PR code runs only in containers (A0). Workers cannot reach the npm registry or its common mirrors; dispatch installs from the base lockfile, first run only (A1). Judge CLIs pinned by version. | Pins are by tag/version, not content. No model gateway. |
| 4 Identity | Keycard broker + zone audit log. Merge App key only in Actions. Statuses only from CI. | Level 1 shape. The brokered token is a repo-wide bearer shared by dispatch and worker; "only your branch and issue" is prose in the worker skill, not an enforced scope. Profile is split between the repo (`policy.json`) and the plugin checkout on the mini (`worker-settings.json`, skills), and neither half is authenticated. |
| Record | Keycard audit + GitHub statuses + Actions logs + Linear comments share a run id. | `~/.factory/logs` and every Linear comment are written by the shared identity, so neither is independent of the worker. |

## Phase A: now, on the mini, no new products

Each is its own PR. Order is by severity of what it closes.

### A0. Judge workflow runs from base, not from the PR (boundary 3, identity)

`templates/factory-judge.yml` triggers on `pull_request`. Worker PRs are same-repo branches, so a PR that edits `.github/workflows/factory-judge.yml` runs its own version of the workflow, with `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`, before the merge gate's `.github/*` deny is ever consulted. The gate protects merge; nothing protects the judge.

Change:
- trigger on `pull_request_target`, so the workflow definition and `.factory/refute-prompt.md` come from base, as `factory-merge.yml` already does. Jobs keep their current permissions: `{}` everywhere except `post`, which keeps `statuses: write`;
- the `checks` job keeps its explicit checkout of `head.sha` with `persist-credentials: false`, drops `cache: npm`, and **never executes PR code on the runner itself**. Under `pull_request_target` the job runs in the base branch's cache and artifact scope, and any PR process left running on the runner can read the runtime token of a later action step (`upload-artifact`) and save a poisoned base-scoped cache. So PR code runs only inside throwaway containers started by `docker run --rm`: one `node:24` container with network for `npm ci --ignore-scripts` (or with scripts if base policy says `install_scripts: true`), then one with `--network none` for every command in `checks`. The container exits before the next step; nothing PR-controlled survives into `upload-artifact`, and nothing PR-controlled can reach the network during a check;
- **the gate stops trusting status contexts by name.** Today `scripts/risk-gate.sh:49` accepts any `factory/judge-*` status in state `success`. A worker PR can add `.github/workflows/anything.yml` on `pull_request` with `permissions: {statuses: write}` and post those two statuses on any SHA with the workflow token; the brokered token's 403 does not apply to a workflow. Revisions 4 through 6 tried to identify the genuine judge run by its metadata (workflow file, event, title, jobs, branch) and Codex found a bypass each time, because every field on a workflow run can be matched by a PR-defined workflow on a worker-pushed branch: a helper PR with the victim's branch as head and `factory/evil` as base runs `factory/evil`'s copy of `factory-judge.yml` under `pull_request_target`, with the victim's `head_sha` and `head_branch`. Checked against real runs on the pilot repo: a `pull_request_target` run's `head_sha` and `head_branch` are the PR head's, not the base's. Metadata cannot say which branch defined the workflow.

  Fix: the verdict carries proof of where it came from. `FACTORY_JUDGE_KEY` (32 random bytes, generated once by onboarding) lives only in the `factory` environment above. The `post` job posts **every** verdict as `<VERDICT> <run id> <attempt> <hmac>` where `hmac = HMAC-SHA256(FACTORY_JUDGE_KEY, "<N>:<HEAD>:<BASE>:<run id>:<attempt>:<model>:<VERDICT>")`, hex, 64 chars; the whole description is under 100 chars. Binding the base SHA means a verdict dies when the base moves. Binding run id and attempt, and signing REFUTED and CAVEATS too, is what makes revocation hold against an attacker who can only append.

  The gate job in `factory-merge.yml`, after the base check, fetches the **whole** append-only status list for the head, or refuses if any page fails (the list is newest-first, so a partial read would show only an attacker's replays). It verifies every entry's signature against its own PR number, head, and base, discards the rest, and per model keeps the signed verdict with the highest `(run id, attempt)`. Both must be VERIFIED and from the same `(run id, attempt)`. A replayed older VERIFIED never outranks a later signed REFUTED; two attempts of one re-run cannot be mixed; forged or legacy descriptions are simply not signed. Three earlier drafts got this wrong in turn (full list without ordering, latest-per-context which replays beat, run id without attempt), each caught by review. A forged workflow on any other branch, or any `pull_request` run, cannot read the key and cannot produce the string; a stale status for an earlier head is bound to the old SHA by construction. Statuses stay the carrier because the full status list is append-only; which entry is genuine is now decided by the signature, not by the poster or the context name. The `post` job still exits non-zero unless both verdicts are `VERIFIED`, so the run's conclusion is honest for humans; the gate does not rely on it;
- **every factory secret moves out of repository secrets** into a GitHub Environment `factory` whose deployment branch policy allows only `main`: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `FACTORY_APP_PRIVATE_KEY`, and the new `FACTORY_JUDGE_KEY`. Repository-level copies are deleted. The two model jobs, the `post` job, and the merge workflow's gate job declare `environment: factory`. Environment access is decided on the run's `github.ref`. Since GitHub's change of 2025-12-08, a `pull_request_target` run always takes its workflow file and `github.ref` from the **default branch**, whatever the PR's base, and environment rules for it evaluate against the default branch; a `pull_request` run evaluates against `refs/pull/N/merge`; a `workflow_run` run against the default branch. So the judge and merge workflows get the secrets and a PR-added workflow never does. The flip side: `github.event.pull_request.base.sha` is still whatever the PR author chose, so both workflows refuse to read policy, prompt, or gate script from a base that is not the default branch (the judge's `checks` job does not start; the merge gate skips before its first `git show`). Today all four secrets are readable by any workflow a worker PR adds, which is the single largest hole this plan closes;
- **the merge gate refuses any PR whose base is not the default branch**, before it reads anything from that base. `templates/factory-merge.yml` runs `git show "$BASE:.factory/risk-gate.sh"` for whatever base the PR has, and a PR author can retarget their PR (`PATCH /pulls/N` with a new `base`, which the brokered token can do on its own PR) to a worker-pushed branch carrying a hostile gate script; that script would then run in the job that holds the merge App key and the HMAC key. The gate step runs only after `baseRefName == default_branch` is checked, and the HMAC verification and App-token steps carry the secrets in their own step env only, never in the step that executes the gate script;
- `run-name: "factory-judge #${{ github.event.pull_request.number }} @ ${{ github.event.pull_request.head.sha }}"`, for readability only. Checked against real runs on the pilot repo: a `pull_request_target` run's `head_sha` and `head_branch` are the PR head's, so the merge workflow's `--search "$RUN_SHA"` and the dispatch skill's `headSha` lookup keep working unchanged.

Done when, each on a test PR against the pilot repo:
- `gh secret list -R <repo>` shows no factory secret at repository level, and `gh api repos/:r/environments/factory` shows the four secrets and a `deployment_branch_policy` of `main` only;
- a PR that adds `.github/workflows/leak.yml` on `pull_request` printing `${{ secrets.FACTORY_APP_PRIVATE_KEY }}`, `${{ secrets.ANTHROPIC_API_KEY }}` and `${{ secrets.FACTORY_JUDGE_KEY }}` through `base64` prints three empty strings. Run this test **first**, before the migration, to see it print the keys today; rotate all three afterward regardless;
- a PR that rewrites `factory-judge.yml` to `echo $ANTHROPIC_API_KEY | base64` is judged by the base version, and the Actions log shows the base workflow's job names;
- a signed PR retargeted to `factory/evil` (whose `.factory/risk-gate.sh` is `env | base64`) gets `review: base factory/evil is not main` from the merge workflow and the gate script is never executed; the job log shows no step after the base check;
- a PR that adds `.github/workflows/forge.yml` posting `factory/judge-claude` and `factory/judge-codex` `success` with description `VERIFIED <64 hex chars>` on its own head SHA gets `review: no signed VERIFIED for factory/judge-claude on <sha>` from the gate, even though `gh api .../status` shows both contexts green;
- a branch `factory/evil` carrying a permissive `.factory/policy.json` and a `factory-judge.yml` whose jobs trivially succeed, plus a PR retargeted to `factory/evil`: GitHub runs `main`'s `factory-judge.yml` regardless (2025-12-08 semantics), its `checks` job is skipped because the base is not the default branch, nothing is signed, and after retargeting back to `main` the gate still reports `review: no signed VERIFIED …`;
- a PR-added workflow that reposts, as newer statuses, a genuine signed VERIFIED pair from run `111` after a re-judge run `222` signed REFUTED: the gate ignores the replay because the signed `222` verdict has the higher run id, and reports `review: no signed VERIFIED for factory/judge-claude(REFUTED) …`;
- a PR-added `re.py` at the repository root: the judge's prompt-building step runs `python3 -I` and never imports it (log shows the prompt built from the real `re`);
- a PR whose test writes `core.fsmonitor = <payload>` into `.git/config`: the containers see an export of the tree with no `.git` at all, and the checkout's post-job cleanup on the runner executes nothing;
- a PR that adds `tests/.gitattributes` with `bad.test.js export-ignore` and a failing `tests/bad.test.js`: the export is made with `read-tree` and `checkout-index`, which ignore `export-ignore`, the file count of the export equals the tree's, and the check fails as it should;
- a run where `judge-codex` failed for an infrastructure reason and was re-run with "re-run failed jobs": `post` sees Claude's attempt-1 verdict next to its own attempt 2 and posts CAVEATS for both, signed; a full re-run of all jobs produces a signed pair from one attempt;
- the same `factory/evil` workflow with `post` not declaring the environment and `secrets.FACTORY_JUDGE_KEY` referenced anyway: the secret is empty in that job, the HMAC is over an empty key, and the gate's recomputation with the real key does not match;
- a PR opened without the `factory` label, then labeled: no signed status exists until the labeled run's `post` job runs; the gate waits on the signature, not on any run's conclusion;
- a genuine VERIFIED at head `A`, then a push to head `B`: the gate for `B` recomputes over `B` and finds no match; the stale signed status on `A` is ignored;
- a genuine VERIFIED at head `A`, then the same head re-judged (relabel) and REFUTED: the combined status shows the REFUTED entry as latest and the gate reports `review: no valid signed VERIFIED …`; the older signed entry is still in the append-only list and still ignored;
- a genuine VERIFIED at head `A` on base `B1`, then `main` advances to `B2` without a new push: the gate recomputes with `B2` and finds no match;
- the gate job in `factory-merge.yml` on the private pilot repo can read `FACTORY_JUDGE_KEY` on both its `pull_request_target` and `workflow_run` paths (verified by a log line that prints the key's length, never the key), and the step that runs `risk-gate.sh` has no `*_KEY` in `env`;
- the repository setting "Allow GitHub Actions to create and approve pull requests" is off, so a PR-added workflow with `pull-requests: write` cannot satisfy the CODEOWNERS review in A5;
- a PR whose test runs `nohup sh -c 'sleep 600' &` and `curl https://example.com`: after the `checks` step, `pgrep sleep` on the runner is empty, the curl failed at connect, and the next `main` run restores no cache;
- the merge workflow resolves the PR from the judge run via `display_title`.

Residual: a PR-added workflow with `actions: write` can re-run the whole judge as often as it likes, which re-rolls two non-deterministic models on the same head; every attempt is genuine and signed, so this is a judge-quality exposure, not a forgery, and the gate's `(run, attempt)` rule only guarantees the pair it accepts came from one attempt. The same workflow can post statuses up to GitHub's 1000-per-context cap and so block a later judge from recording anything; that blocks merges (fail closed), and the only VERIFIED signatures it could preserve are genuine ones for that exact head and base, so it cannot produce a false merge. `gh pr merge --match-head-commit` binds the head only; a PR retargeted to an unprotected worker branch in the instant between the merge step's own base re-check and the merge call would be squash-merged into that branch by the App. Worst case is an App commit on a branch the worker already controls, never on `main`. A PR-added workflow still gets the workflow token with whatever `permissions:` it asks for (`contents: write`, `actions: write`, `pull-requests: write`); no repository setting prevents a workflow file from requesting them. Branch protection stops pushes to `main`, the environment stops secret reads, the "create and approve" setting stops self-approval, and the merge requires the App key, which it cannot get. What such a workflow can still do: delete runs (A3), post unsigned statuses, open or edit PRs, push to unprotected branches. The `checks` job still executes PR code, inside a container with no secrets, no network during checks, and no runner process access. Docker-escape is the remaining path, and it is the same residual GitHub-hosted runners carry for everyone. The lockfile that `npm ci` installs from is the PR's; with `--ignore-scripts` nothing in it executes during install, and what it installs runs only with `--network none`. The gate's lockfile deny is the admission control for what gets merged, not for what gets installed in the judge.

### A1. Close the npm registry hole (boundary 2 and 3)

Workers are forbidden from changing manifests, so they have no legitimate reason to fetch a package. Today `registry.npmjs.org` and `*.npmjs.org` are on the allowlist, so a worker can `npm install <anything>` and run its install scripts inside a process that holds `GH_TOKEN` and `LINEAR_TOKEN`.

Change:
1. Move the npm registry hosts from `allowedDomains` to `deniedDomains` in `worker-settings.json`. Absence from the allowlist only routes to the classifier; denial is explicit. This denies the registry, not the `npm` client.
2. Dispatch warms `node_modules` once per fresh worktree, before the worker starts, with `npm ci --ignore-scripts` against the committed lockfile. Always `--ignore-scripts`: dispatch runs as the logged-in uid with keychain access, and `scripts/pr.sh:24` shows that any process in that uid can re-invoke `keycard agent exec` and get tokens back, so unsetting two variables does not make an install-script credential-free. Projects whose dependencies need install scripts are not supported by the warm-up; their packages install without their lifecycle work, so a `checks` command that needs it fails, which routes the issue to Needs Input. The warm-up installs registry tarballs only: `--ignore-scripts` does not stop a git dependency's own `.npmrc` from choosing the git binary npm runs, so the install is skipped unless the lockfile is v2 or newer and every installed entry either resolves to a `registry.npmjs.org` tarball or, where npm omitted `resolved`, has a plain semver `version` (a v1 lockfile can carry a git dependency in `version` alone; a v2+ git dependency always has a `resolved` URL); that project runs cold. The install runs with an environment of only `HOME` and `PATH`, `--userconfig=/dev/null`, `--globalconfig` at a nonexistent path (npm refuses one path for both), `--registry=https://registry.npmjs.org/` and `--replace-registry-host=never`, so npm's configuration is the command line plus base's own `.npmrc`, which is trusted exactly as far as base's lockfile is. The install is bounded at 5 minutes per repo; the sweep lock goes stale at 60, so the registry holds at most 11 repos before the lock needs renewing. The judge's `checks` job in CI (no secrets, no keychain) is where `install_scripts: true` in base policy may enable scripts.

Done when: a worker that runs `npm install left-pad` sees a sandbox denial for `registry.npmjs.org` in its log; a fresh worktree passes `npm test` with no outbound connection from the worker's process group to the registry (verified from the `pf` log in A4, or from the sandbox log before A4 lands).

Residual: `npm install github:owner/repo` and `npm install https://…/x.tgz` still work, because `codeload.github.com` and `objects.githubusercontent.com` stay allowed for git and the `npm` client is not what is denied. So do `curl | sh` from an allowed host, and a package already in `~/.npm/_cacache`. The deny list names the registry and its common mirrors (yarnpkg, npmmirror, GitHub Packages) by hostname; a mirror not on the list reaches the `auto` classifier, and an IP literal is not a hostname at all. A4 is the layer that sees addresses. The warm-up is npm only (`package-lock.json` or `npm-shrinkwrap.json`) and runs only on the first run from the base tree; a retry worktree is the worker's branch and is never installed from. pnpm and yarn projects get no warm-up, so onboarding one is premature until it does. A `checks` or `check_setup` command that itself fetches from the registry (`npx <pkg>@<ver>`) fails in the worker, though CI's setup container still has network; pin such tools as devDependencies instead. What A1 closes is the default path that runs third-party code with one command; it does not close deliberate download-and-execute. The seatbelt confines the write set; the tokens in the worker's environment are the exposure, and only Phase B's credential-free worker removes them.

### A2. Pin by content, install from trusted sources (boundary 3)

In both workflow templates:
- every `uses:` pinned to a full 40-hex commit SHA with the tag in a trailing comment;
- the judge's `checks` job runs `npm ci --ignore-scripts` unless base `policy.json` sets `install_scripts: true`;
- the two CLI installs stop being `npm i -g <name>@<version>` resolved at run time. The plugin ships `templates/judge-tools/package.json` + `package-lock.json` with both CLIs as pinned dependencies; onboarding copies them to `.factory/judge-tools/` in the target repo; each model job installs from **base** (`git show "$BASE:.factory/judge-tools/package-lock.json"`) into `$RUNNER_TEMP/tools` with `npm ci --ignore-scripts`, calls the binary by path, and does this in a step **before** the step that exposes the API key. The PR checkout is never the source of the tools that judge it.

Dependabot config for `github-actions` and `.factory/judge-tools`, so pins move by PR, which the gate's `.github/*` and `.factory/*` deny routes to me.

Done when: `grep -ohE '(^|[ {])uses: *[^ ,}]+' templates/*.yml | grep -vE '@[0-9a-f]{40}$'` prints nothing (the leading anchor keeps `statuses: write` out of the match; today it prints five `@v` tags) (every `uses:` occurrence is extracted wherever it sits in the YAML, including inline `{ uses: … }` maps, and the allowed format is validated rather than forbidden prefixes enumerated); a PR that edits `.factory/judge-tools/package-lock.json` to point at a different package is judged with the base tools (the Actions log shows the base lockfile's integrity hashes); the install step for each model job runs with no `*_API_KEY` in its environment (assert with `env | grep -c _API_KEY` = 0 in that step); both `factory/judge-*` statuses are `success` on the pilot repo after the change.

Residual: npm's integrity field verifies the tarball, not its provenance. Transitive deps are fixed, not vetted.

### A3. Name the independent records; stop counting the rest (record)

Dispatch and the worker share uid 502 and the same Linear identity, so neither `~/.factory/logs` nor any Linear comment can be tamper-evident against the worker: `chflags uappnd` on a directory does not propagate to files, the owner can clear the flag, and the worker can edit or delete the claim comment dispatch wrote. Revisions 1 and 2 claimed more than this and were wrong both times.

Change: the plan and `docs/writeup.md` state which records are independent of the worker and which are not.
- Independent as to **authorship and deletion**: HMAC-signed `factory/judge-*` entries in the full commit status list (`GET /repos/:r/commits/:sha/statuses`). The list is append-only, and only a workflow taken from `main` can produce a valid signature (A0). Forged entries can be added beside them and are detectable by signature; genuine ones cannot be removed.
- Independent as to **authorship** only: the logs of `pull_request_target` runs of `factory-judge.yml` and `factory-merge.yml` from `main` (a PR cannot redefine them, but can delete them, see Residual); the merge App's squash commits, **once A0 has moved the App key into the environment** (today a PR-added workflow can mint App tokens); Keycard's zone audit log, which records every credential **exchange** (not every subsequent API call made with the exported bearer).
- Not independent either way: Linear comments, the PR body, the local log.
- The `post` job keeps posting statuses so the append-only list exists, and the perl wrapper uploads the local log to the Linear issue at exit as context, labeled as such.
- Not independent: Linear comments, the PR body, the local log. These are convenience and context.
- The perl wrapper uploads the local log to the Linear issue at exit as context, labeled as such.

Done when: with the local log deleted and the Linear claim comment edited to a different run id mid-run, the run is still reconstructible from GitHub and Keycard alone: head SHA, both verdicts, merge or no merge, and every token exchange in the window, and the reconstruction disagrees with the edited Linear comment, which is the point.

Residual: a same-repo PR can add a workflow with `permissions: {actions: write}` and `DELETE` genuine judge runs. No repository setting prevents a workflow file from requesting that permission; the "read-only default" setting only changes the default. Deleting a run cannot produce a merge (the gate reads signed statuses, which deletion does not touch), and the forging PR itself can never merge (`.github/*` deny plus CODEOWNERS), but the run's logs and the judges' findings artifacts are gone. What survives deletion: the append-only status list with the signed verdict lines, the Keycard audit entries, and the GitHub audit log entry for the deletion itself, which names the workflow run that did it. Run-level identity (which worker did what) lives only in those records' timestamps and SHAs, not in a signed claim. A second identity for the worker is the Phase B broker.

### A4. Kernel-level default-deny egress for unknown destinations (boundary 2)

`pf` rules scoped to uid 502 on the mini: allow outbound 443 to a table of GitHub, Linear, Anthropic, OpenAI, Keycard, and npm registry addresses; allow DNS to the configured resolver; deny and log everything else. The npm registry stays in the kernel allowlist on purpose: the kernel rule's job is "no host we never named," and A1's `deniedDomains` is the layer that says "and the worker specifically may not use the registry." Dispatch's warm-up needs the registry and shares the uid, so the kernel cannot be the one to draw that line.

GitHub's address ranges change; a LaunchAgent refreshes the `pf` table from `https://api.github.com/meta` daily. IPv6 is covered by the same tables. Rules live in `/etc/pf.anchors/factory` and are loaded by `/etc/pf.conf`, both admin-owned; `softwarefactory` cannot edit them.

Done when: as uid 502, `curl https://example.com` fails at connect (not at TLS, not at HTTP), the `pf` log shows the drop, and `scripts/dispatch.sh` completes a sweep that starts a worker that opens a PR. Repeat after a reboot.

Residual: `pf` sees addresses, not hostnames, methods, or repositories. A worker can reach any GitHub repo and any Linear workspace the token allows. That is the identity residual, not a network one, and it stays until the token is scoped (Phase B). The in-agent allowlist stays as the hostname layer; the kernel layer is the one that holds when the agent does not cooperate.

### A5. Pin and record the profile (boundary 4, Level 2 shape)

The profile is in two places: `.factory/policy.json` in the repo (read from base by the gate and judge) and the plugin checkout on the mini (`worker-settings.json`, skills, `CLAUDE-factory.md`). Signing commits on the pilot repo authenticates the first half only.

Change:
- the mini's plugin checkout is pinned to a tag; `dispatch.sh` refuses to run if `git -C "$root" status --porcelain` is non-empty or `HEAD` is not the pinned tag, and writes the plugin commit SHA and the base policy's blob SHA into the Linear run claim comment and into the PR body's `factory-run:` line;
- branch protection on the pilot repo's `main` requires signed commits and a review for `.factory/**` and `.github/**` (CODEOWNERS = me). The merge App's squash commits are GitHub-signed, so the auto-merge path is unaffected;
- the worker already reads `.factory/policy.json` from its worktree only to learn `checks`; the gate and judge read it from base. Document that split; it is correct as is.

Done when: a dirty plugin checkout makes `dispatch.sh` exit 1 with the reason; an unsigned push to `main` is rejected; a PR touching `.factory/policy.json` cannot merge without my review even with `auto_merge: true` and two green judges.

Residual: the mini's plugin checkout is pinned by convention and verified by a script in the same uid that could edit it. Nothing outside uid 502 verifies it. The Phase B broker is the trusted launcher that does.

### A6. Model and budget move into the profile (boundary 3, model gateway stand-in)

`policy.json` gains `model`, `max_turns`, `max_minutes`. Dispatch validates each: present, integer, `1 ≤ max_turns ≤ 200`, `5 ≤ max_minutes ≤ 90`, `model` from a fixed list in the plugin. The upper bound on minutes stays at today's 90 because the dispatch state table treats an `In Progress` issue with no `factory:` comment newer than 2h as stale and retries it; a longer worker would overlap its own retry in the reused worktree. The stale threshold becomes `max_minutes + 30` from the same policy, so the two cannot drift apart. Dispatch passes `--model` and `--max-turns` and sets the alarm from the validated values.

Done when: `scripts/test-risk-gate.sh` gains a case with `auto_merge: true` at base where a PR that edits `max_turns` is routed to review (the existing suite would pass vacuously because `auto_merge: false` already reviews everything); dispatch rejects each of `max_turns: 10000`, `max_minutes: 0`, `max_minutes: 91`, and `model: "gpt-6"` with a comment on the issue and no worker started; a worker with `max_minutes: 5` is killed at 5 minutes and the issue is not retried until minute 35.

Residual: this is a versioned default, not a gateway. The worker's Claude login and the judges' API keys can still call any model their credentials allow. Provider-side spend limits on both accounts are the only aggregate ceiling and are set by hand.

### A7. Run id in every record, from a stable source (record)

The run id is minted by dispatch and written to the Linear claim comment before anything starts. Add it to the Actions job summary of both workflows (read from the PR body's `factory-run:` line, labeled "worker-supplied") and keep it in the log filename.

Done when: given only the Linear issue, the run id resolves to the PR, the head SHA, both judge Actions runs, the merge run, and the Keycard audit entries for that window, with one grep each.

Residual: the association between a run id and a PR or SHA is asserted by the worker (it writes the PR body) and by dispatch (same identity). No independent component verifies it, so a worker can write another run's id into its PR and the chain resolves to the wrong run. Until the Phase B broker opens PRs on the worker's behalf and stamps the run id itself, A7 is discoverability, not provenance. Keycard audit entries carry principal and resource, not the factory run id; correlation is by time window.

### A8. The workflow as code, not prose (Level 2)

The dispatch state table, claim, retry budget, and pause check are instructions to an LLM in `skills/factory-dispatch/SKILL.md`, running with `bypassPermissions`. The reference's "predefined steps" means enforced transitions. Move the state machine into `scripts/dispatch.sh`: read issues, compute transitions deterministically, and invoke `claude -p` only to start a worker. `scripts/linear.sh` adds the comment author's user id alongside the display name, and the state machine counts `factory:` control comments only from the id the token's `viewer` query returns. Linear comments are inputs to the state machine, never commands to an agent.

Done when: `scripts/test-dispatch.sh` drives the state function with fixture issues and asserts every transition in the table, including a `factory: retry 5` comment whose author id is not the viewer id (must not count), and a duplicate claim that must not start two workers.

Residual: the worker holds the same Linear token, so a `factory:` comment it writes has the viewer's id and counts. Author-id checks stop other humans from steering the factory through comments; they do not stop the worker. Removing the LLM from the control path is the gain here; separating the identities is Phase B.

## Phase B: engineering projects, not product blockers

The mini exists, so hardware is not the blocker; these are larger changes with migration cost, and that is the honest reason they are later. They are one project with four acceptance areas, because the broker is what each of the others needs.

- **Credential broker and trusted launcher.** A second macOS user, `factorybroker`, holds the Keycard session; `softwarefactory` holds nothing. The broker is the only process that runs `keycard agent exec`. It launches each worker (so it knows the worker's process group and worktree before the worker exists), verifies the plugin checkout digest and the base policy blob before launch, mints the run id, writes the claim comment and the PR body header itself, and serves a unix socket with exactly five operations, all scoped to the caller's run: read this run's issue; set this run's issue state to one of `👀 Needs Input` or `👓 In Review` (the two transitions the worker skill makes today, `skills/factory-worker/SKILL.md` steps 0 and 3); push this run's branch; open or update this run's PR; comment on this run's issue with a `factory-worker:` prefix. `scripts/linear.sh` and `scripts/pr.sh` become thin clients of the socket and lose their `keycard agent exec` re-exec paths (`scripts/linear.sh:28`, `scripts/pr.sh:24`), so a worker with no token has no fallback that acquires one. Caller identity is the socket peer's pid resolved to a process group the broker launched, never a run id the caller names. The reserved `factory:` prefix is not available to workers at all. Acceptance: a worker that tries to push to `main`, push another branch, open a PR from another branch, comment on another issue, write a `factory: retry` comment, or claim another run's pgid is refused and the refusal is logged by the broker's uid; `ps -U softwarefactory` shows no process with a token in its environment; a Linear `factory:` comment can only have been written by the broker.
- **A sandbox the agent can't escape.** Ephemeral container per run on the mini. The run gets a full clone, not a worktree: a worktree's `.git` is a file pointing into the main checkout, which would be outside the mount. Only mounts: the clone and the broker socket. No host keychain, no `~/.factory`. Acceptance: the worker cannot read `~/.factory` or another run's clone, leaves no process after the run, and a host file outside the mount is unchanged after a worker that tries to write it; `git push` through the broker still works from inside.
- **Package admission at fetch.** With A1 and A2 the only fetches are dispatch's warm-up on the mini and the judge's `npm ci` container in CI. On the mini, a registry proxy with an allowlist and a cooldown becomes the only route: the `pf` table drops the registry's own addresses and allows only the proxy. In CI there is no kernel layer to force the proxy, and `npm_config_registry` is advice a lockfile's tarball URLs ignore, so CI is not an admission point and the plan does not call it one. What CI has instead is A0: install with scripts off, run with no network, no secrets. Admission for anything that reaches `main` is the gate's lockfile deny plus my review. Acceptance: on the mini, `npm install` of a package published less than the cooldown ago fails and a direct connection to `registry.npmjs.org` from uid 502 is dropped; in CI, a check that tries to reach the registry during tests fails at connect.
- **Model gateway.** All model calls, from the worker *and from both judges*, through one endpoint with per-run budgets and an approved list. The judges' secrets become gateway keys, not provider keys; the worker's Claude login gets the gateway as its base URL. Acceptance: `gh api repos/:r/environments/factory/secrets` lists no `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`, only gateway keys, and no such secret exists at repository level or in any other environment; a direct call to `api.anthropic.com` from uid 502 is dropped by `pf`; the gateway refuses a model not in the list and a run that exceeds its budget, and both refusals show as REFUTED or Needs Input, not as a hang.

## What this does not change

Approval stays with me (`auto_merge: false`). The two-model judge stays. The gate stays deterministic and runs from base. Nothing in this plan gives any agent more authority than it has now; every item narrows one, and every item says what it leaves open.

## Codex reviews

Run: `codex exec --sandbox read-only -c model_reasoning_effort=high` against this repo, 2026-10-27, model `gpt-6-astra`, with the instruction to refute and to report only findings not already admitted in an item's residual. Every finding was checked against the cited file and line before being adopted.

### Revision 1: REFUTED, 15 findings

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| A1: removing npm from the allowlist is not a denial; dispatch inherits the tokens; GitHub stays a download source | BLOCKER | Yes | `deniedDomains`; warm-up changes; residual stated |
| A2: judge jobs check out PR head, so a lockfile there is PR-controlled; onboarding doesn't copy the tools; `@v` grep misses `@main` | MAJOR | Yes | Tools installed from base into `$RUNNER_TEMP`; onboarding copies; grep rewritten |
| A3: same uid, `uappnd` doesn't propagate, dispatch doesn't wait for the worker | BLOCKER | Yes | Item rewritten |
| A4: `pf` by uid blocks dispatch's warm-up; IPs not hostnames; DNS | BLOCKER | Yes | npm stays in the kernel allowlist; DNS rule; residual stated |
| A5: signed commits authenticate base, not the runtime profile on the mini | BLOCKER | Yes | Plugin checkout pinned and recorded; CODEOWNERS review |
| A6: gate test vacuous while `auto_merge: false`; no validation of values | MAJOR | Yes | Test fixture with `auto_merge: true`; validation |
| A7: PR body is worker-authored and rewritten on retry | MAJOR | Yes | Linear claim comment named as source (corrected again in rev 3) |
| A8: documentation only; the state machine is prose to an LLM | MAJOR | Yes | State machine into `dispatch.sh` with a fixture test |
| B-EGRESS: credential attachment alone does not close network | MAJOR | Yes | Rewritten as the broker; layers kept |
| B-SANDBOX: the mini exists, so "hardware" is not the blocker | MAJOR | Yes | Phase B reframed as engineering |
| B-PACKAGES: a registry is bypassable; judge CLI installs run with API keys present | MAJOR | Yes | A2 installs tools before the key step |
| B-MODEL: a gateway only counts if direct calls are impossible | MAJOR | Yes | Acceptance adds the `pf` drop |
| MISSING-IDENTITY: the token is a repo-wide bearer; "your branch only" is prose | BLOCKER | Yes | Identity row reworded; broker is the fix |
| MISSING-CI-TRUST: `factory-judge.yml` runs on `pull_request` | BLOCKER | Yes, pre-existing | New item A0 |
| PHASE-SPLIT: Phase A overclaims, Phase B underclaims feasibility | MAJOR | Yes | Residuals on every item |

### Revision 2: REFUTED, 19 findings

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| A0: `pull_request_target` puts the PR-executing `checks` job in the base cache scope; `cache: npm` lets PR code poison trusted runs | BLOCKER | Yes | `cache: npm` dropped; test added |
| A0: under `pull_request_target` the run's head SHA is base, so merge.yml and the dispatch findings lookup break | MAJOR | **No.** Accepted in rev 2, disproved in rev 7 against real runs on the pilot repo: a `pull_request_target` run's `head_sha` is the PR head. The existing lookups keep working. | `run-name` kept for readability; the `displayTitle` matching was dropped with the rest of the metadata approach |
| A0: "every job at `permissions: {}`" would strip `post`'s `statuses: write` | MAJOR | Yes | Wording fixed |
| A1: `deniedDomains` denies hosts, not the npm client; the GitHub example would fail for the wrong reason | MAJOR | Yes | Example removed; residual lists the GitHub and tarball paths |
| A1: unsetting two variables is not credential-free; `pr.sh:24` re-invokes Keycard; install scripts with `install_scripts: true` run in the dispatcher's uid | MAJOR | Yes | Warm-up always `--ignore-scripts`; `install_scripts` applies to CI only |
| A2: the grep accepts `@release`, `@canary`, short SHAs | MINOR | Yes | Validate the allowed format |
| A3: dispatch and worker share the Linear identity, so the claim comment is not independent | BLOCKER | Yes | Item rewritten around which records are actually independent |
| A3: Keycard records exchanges, not every use of the exported bearer | MAJOR | Yes | Wording corrected |
| A6: no positive minimum; `max_minutes: 0` disables the alarm | MAJOR | Yes | Bounds on both ends; test cases |
| A6: a 180-minute ceiling overlaps the 2h stale-run retry | MAJOR | Yes | Ceiling 90; stale threshold derived from `max_minutes` |
| A7: the run-id-to-PR association is worker-asserted; a false chain resolves | MAJOR | Yes | Residual states it; broker stamps it in Phase B |
| A8: `linear.sh` exposes comment authors as display names only; a renamed user can forge control comments | MAJOR | Yes | Author user id added; viewer-id check; residual notes the worker shares the id |
| B-CREDENTIALS: a shared uid and socket don't bind a caller to a run; "comment on my issue" still allows `factory:` control comments | MAJOR | Yes | Broker launches the worker and binds by pgid; `factory:` prefix reserved |
| B-SANDBOX: mounting only the worktree hides its `.git` file | MAJOR | Yes | Full clone per run |
| B-PACKAGES: the registry proxy is optional unless direct registry access is dropped | MAJOR | Yes | `pf` drops the registry; proxy is the only route, for CI too |
| B-MODEL: judges in Actions bypass a gateway enforced on the mini | BLOCKER | Yes | Judges' keys become gateway keys; no provider key in the environment |
| B-PROFILE: the trusted launcher has no entry or acceptance test | MAJOR | Yes | Broker is the launcher; digest verification in its acceptance |

### Revision 3: REFUTED, 4 findings

Prompt for this round told the reviewer to report only findings not already admitted as a residual, and to use REFUTED only when a BLOCKER survives.

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| A0: dropping the cache does not revoke cache access; a background process left by PR code can read a later action step's runtime token and save a base-scoped cache | BLOCKER | Yes | PR code runs only in `docker run --rm` containers; checks run with `--network none`; test for a surviving process |
| A3: a worker PR can add its own `pull_request` workflow with `statuses: write` and forge `factory/judge-*` on any SHA; `risk-gate.sh:49` accepts by context name | BLOCKER | Yes, pre-existing | Gate verifies a successful run of the workflow file `factory-judge.yml` by `display_title`; `post` fails unless both verdicts are VERIFIED; statuses become advisory |
| B-CREDENTIALS: the broker's three operations omit the worker's issue read and state transitions; `linear.sh` would fall back to a Keycard re-exec | BLOCKER | Yes | Five operations; thin clients with the re-exec removed |
| B-PACKAGES: `npm_config_registry` in CI is bypassable by PR-controlled tests | BLOCKER | Yes | CI is no longer called an admission point; checks run with no network |

### Revision 4: REFUTED, 3 findings, all on A0's new verdict lookup

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| A0: a PR can edit `factory-judge.yml` to add a `pull_request` trigger and a forged `run-name`; the workflow-file endpoint lists that PR-defined run too | BLOCKER | Yes | Gate requires `event == pull_request_target` |
| A0: an unlabeled PR produces a run whose jobs are all skipped and whose conclusion is `success`; labeling afterward leaves it matching | BLOCKER | Yes | Gate requires all four named jobs concluded `success` |
| A0: the runs lookup needs `actions: read` on a private repo; `factory-merge.yml` omits it | MAJOR | Yes | Permission added |

### Revision 5: REFUTED, 2 findings

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| A0: the worker token can push any branch; a PR against a worker-made branch gets a `pull_request_target` run defined by that branch, passing all four conditions | BLOCKER | Yes | Condition 5: run `head_branch` must be the default branch; ruleset restricts branch creation to `factory/*` |
| A3: a PR-added workflow with `actions: write` can delete genuine judge runs, destroying the record | MAJOR | Yes, and no setting prevents it | Admitted as residual; the append-only status list and the GitHub audit log are what survive |

### Revision 6: REFUTED, 1 finding

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| A0: `head_branch` is the PR head, not the workflow's base; a helper PR with head = victim branch, base = `factory/evil` passes all five conditions | BLOCKER | Yes, verified against the pilot repo's runs | The metadata approach from revisions 4 through 6 is abandoned. The `post` job signs each verdict with an HMAC key that only a workflow taken from `main` can read (environment deployment branch policy); the gate verifies the signature. Ruleset and `actions: read` dropped as no longer load-bearing. |

### Revision 7: REFUTED, 2 findings, both pre-existing

Codex confirmed that only a workflow taken from `main` can reach the environment's secrets. Its statement that environment access for `pull_request_target` is decided on the PR's base ref was true until 2025-12-08 and is corrected in the implementation review below.

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| A0: the merge gate runs `.factory/risk-gate.sh` from the PR's base, and the PR author can retarget the base to a worker-pushed branch; the hostile gate script then runs in the job holding the App key and the HMAC key | BLOCKER | Yes, pre-existing | Gate refuses any PR whose base is not the default branch before reading from it; secrets confined to their own steps |
| A3: `FACTORY_APP_PRIVATE_KEY` is a repository secret; a PR-added workflow can print it and mint merge-App tokens | MAJOR, but in fact the most severe thing found | Yes, pre-existing, and the same holds for both model API keys today | All four secrets into the `factory` environment, repository copies deleted, keys rotated; "create and approve PRs" setting off |

### Revision 8: CAVEATS, 2 findings

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| A2: the pin grep misses inline `{ uses: … }` maps, so every action can stay unpinned while the check passes | MINOR | Yes, reproduced by Codex | Grep extracts every `uses:` occurrence regardless of YAML shape |
| B-MODEL: acceptance named the old `factory-judge` environment, so an empty legacy environment would pass while the judges keep provider keys | MAJOR | Yes | Acceptance names `factory` and requires no provider key anywhere |

### Implementation of A0: Codex review of the diff, REFUTED, 5 findings

Run against `git diff main...HEAD` after A0 was implemented in the templates. All five valid; two were pre-existing in the judge template.

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| The prompt-building `python3 -` runs with the PR checkout as cwd, so a PR-added `re.py` executes with the model's API key in the next step | BLOCKER, pre-existing | Yes | `python3 -I` |
| The checks containers mounted the checkout including a writable `.git/config`; `core.fsmonitor` set by PR code runs on the host during `actions/checkout`'s post-job cleanup | BLOCKER | Yes, Codex reproduced the primitive | Containers get a `git archive` export of the tree; no `.git` inside |
| Since 2025-12-08 `pull_request_target` takes workflow and `github.ref` from the default branch, so environment access no longer depends on the PR's base; but the judge still read policy and prompt from the attacker-chosen base | MAJOR | Yes, verified against GitHub's changelog | Judge `checks` job starts only when the PR's base is the default branch; plan text corrected |
| Replay: a PR-added workflow can repost an older signed VERIFIED pair as the newest statuses after a later run signed REFUTED; latest-per-context then accepted it | MAJOR | Yes | Every verdict is signed; the gate verifies the whole append-only list and takes the highest run id per model |
| The base name was checked from a second `gh pr view` call, separate from the one that captured the base SHA | MAJOR | Yes | One call, one snapshot |

### Implementation of A0, second pass: REFUTED, 3 findings

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| Re-run attempts keep the run id, so one model's VERIFIED from attempt 1 and the other's from attempt 2 combine; a PR-added workflow can trigger re-runs with `actions: write` | BLOCKER | Yes | Attempt number signed and ordered with the run id; both verdicts must share `(run, attempt)` |
| `gh api --paginate` in a process substitution fails open: a page failure after the newest (replayed) entries leaves the higher-run REFUTED unseen | BLOCKER | Yes | Whole list fetched into a variable first; any failure refuses |
| A retarget between the gate and `gh pr merge` merges into the new base; `--match-head-commit` binds only the head | MAJOR | Yes | Base re-checked in the merge step; the remaining instant is an admitted residual |

### Implementation of A0, third pass: REFUTED, 3 findings

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| `git archive` honors a PR-controlled `.gitattributes` `export-ignore`, so a failing test can be hidden from the checks container while remaining in HEAD | BLOCKER | Yes | Export via `read-tree` + `checkout-index`, which ignore it; file count must equal the tree's |
| "Re-run failed jobs" reuses one judge's outputs from an earlier attempt; `post` signed both with its own attempt | BLOCKER as filed; in practice both verdicts are genuine for the same head and base | Yes | Each judge job outputs its attempt; `post` refuses to sign a verdict from another attempt |
| Filling both contexts to the 1000-status cap blocks a later REFUTED from being recorded | MAJOR | Not a false-merge path: the only signatures it can preserve are genuine ones for that head and base; any base move invalidates them | Documented as a residual (denial of service, fails closed) |

### Implementation of A0, fourth pass: REFUTED, 3 findings

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| The export's file-count check rejects legitimate trees: a filename with a newline, or an existing submodule (gitlink counted on one side only) | BLOCKER | Yes | Count blobs by object mode, excluding gitlinks; count export entries NUL-separated |
| `check_setup` was moved after `npm ci`; a policy that prepares the lockfile in `check_setup` broke | BLOCKER | Yes, regression | Order restored: `check_setup`, then `npm ci` |
| `checkout-index` honors the `ident` attribute, so the export is not byte-identical to HEAD | MAJOR | No: every checkout, including the one that ships, expands `$Id$` the same way; the export matches what runs anywhere | Not adopted |

### Implementation of A0, fifth pass: REFUTED, 1 finding

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| `check_setup` entries and `npm ci` ran in one shell; a `cd` or `exit` in an entry leaked into the install, where before each entry had its own `bash -c` | BLOCKER | Yes, regression | Entries run one per `bash -c` inside the container again |

### Implementation of A0, sixth pass: REFUTED, 1 finding

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| State that `check_setup` left outside the workspace (`/tmp`, `$HOME` caches) was gone when the checks ran in a fresh container | BLOCKER | Yes, regression for such policies | One host directory is mounted as `/tmp` (which is `HOME`) in both containers |

### Implementation of A0, seventh pass: VERIFIED

"No new findings beyond the documented residuals and dispositions." Seven passes on the implementation: 5, 3, 3, 3, 1, 1, 0 findings. Four of the sixteen were pre-existing holes in the judge template (python import from the PR checkout, `pull_request` trigger, repository secrets, status-by-name gate); the rest were defects in this branch's own first drafts, three of them regressions that a reviewer with the old template open caught.

Not adopted, any round: "continuous external checkpoints" and "authenticated completion records" for the log, and per-run gateway authorization as a Phase A item. Each is the Phase B broker by another name; adding them to Phase A would be the same work twice.

### Implementation of A1: Codex review of the diff, REFUTED, 7 findings

Run against `git diff main...HEAD` after A1 was implemented (deny list, dispatch warm-up, docs).

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| The warm-up also ran on retry, where the worktree is the worker's branch: a worker can push a lockfile pointing at its own host plus an `.npmrc` with `_authToken=${GH_TOKEN}`, delete `node_modules`, and dispatch installs from it with the token in its environment | BLOCKER | Yes | Install only on the first run, when the tree is `origin/HEAD`; the two brokered tokens are dropped from the install's environment |
| `! -d node_modules` is not "installed": a failed `npm ci` leaves a partial directory that the next run skips | MAJOR | Yes | A failed install removes `node_modules` and fails prep; retries never install, so a broken tree fails its checks and routes to Needs Input |
| No deadline on the install; a long one pushes the worker's 90 minutes past the 2h stale threshold and the dispatcher past its 60-minute lock | MAJOR | Yes | `alarm 600` around `npm ci` |
| `npm-shrinkwrap.json`, pnpm and yarn projects skip the warm-up while the worker is told its dependencies were installed | MAJOR | Yes | Shrinkwrap accepted; the worker skill says "if the repo has an npm lockfile"; pnpm/yarn named as a residual |
| A `checks` or `check_setup` command that fetches from the registry itself (`npx`) now fails locally while CI's networked setup still works | MAJOR | Yes, as a residual | Named in the residual with the fix (pin as a devDependency) |
| The verification shown (two curl 403s, an empty scratch project) does not establish the done-when: it needs a dependency-bearing fixture that passes its suite cold with no registry reachable | MAJOR | Yes | Re-verified on an export of the pilot repo: warm-up from its lockfile with the registry reachable, then `npm test` with the registry denied |
| README, writeup and the plan table said "cannot fetch and run a package"; the residual says otherwise | MINOR | Yes | Wording narrowed to the registry and its mirrors |
| "Runs cold" misdescribes `--ignore-scripts`: packages install, their lifecycle work does not | MINOR | Yes | Reworded |

Pre-existing, not adopted here: the README's "no local process holds a credential" overstates what Keycard brokering gives (dispatch and workers hold the brokered tokens for the run); that is the Phase B credential-free worker.

### Implementation of A1, second pass: REFUTED, 4 findings

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| `--ignore-scripts` does not make a git dependency code-free: the dependency's own `.npmrc` can name the git executable npm runs, and dispatch installs outside any sandbox with keychain access | BLOCKER | Yes | The warm-up refuses a lockfile with any `resolved` URL that is not a `registry.npmjs.org` tarball; such a project runs cold |
| `alarm 600; exec` kills npm alone; git or ssh children survive outside every timeout | MAJOR | Yes, reproduced by Codex | Same construction as the worker launch: own process group, TERM then KILL to the group |
| The worker skill promised an install whenever a lockfile exists; a recreated retry worktree gets none | MINOR | Yes | Reworded: first run only, registry tarballs only, uncached requests |
| A1's own text still said "cold `node_modules`" after the record claimed the wording was fixed | MINOR | Yes | Fixed in the plan item |

### Implementation of A1, third pass: REFUTED, 4 findings

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| The `resolved`-URL guard misses a v1 lockfile, which can carry `git+ssh://…` in `version` with no `resolved`; Codex ran the predicate and npm's parser to show it | BLOCKER | Yes | Guard requires `lockfileVersion >= 2` and, on every `node_modules/` entry that is not a workspace link, a registry tarball `resolved` or, where npm omitted `resolved` (173 of the pilot's entries), a plain semver `version` |
| npm rewrites an accepted `registry.npmjs.org` URL to whatever registry `.npmrc` or `npm_config_registry` names, so the URL check did not constrain the destination | MAJOR | Yes | `--registry=https://registry.npmjs.org/ --replace-registry-host=never --userconfig=/dev/null` on the command line; verified that `npm_config_registry` pointing at a denied mirror still installs from npmjs only. Pass 4 showed `@scope:registry` still got through; see below |
| A guard refusal called `fail` after the worktree existed; the retry then tried to pull a branch never pushed and the issue went to Blocked instead of running cold | MAJOR | Yes | Refusal skips the install and the worker starts cold; a failed install removes the worktree and branch so the retry starts fresh |
| The worker skill still promised an install on every first run | MINOR | Yes | Conditioned on an eligible lockfile |

### Implementation of A1, fourth pass: REFUTED, 3 findings

| Finding | Severity | Valid? | What changed |
|---|---|---|---|
| `@scope:registry` from `npm_config_*` or the global config still redirects an accepted entry that has no `resolved`; Codex ran npm's config loader with the three flags and `npm_config_@example:registry` and got yarnpkg | MAJOR | Yes | The install's environment is `HOME` and `PATH` only, plus `--globalconfig` at a nonexistent path; npm's config is now the command line and base's `.npmrc`, which is trusted as far as base's lockfile is. Verified on the pilot export with `npm_config_@biomejs:registry` pointing at the yarn mirror: the unscrubbed install requested `@biomejs/biome` from the mirror, the scrubbed one installed all 669 packages from npmjs |
| The 10-minute bound is per install; a sweep over several repos could outlive the 60-minute dispatch lock | MAJOR | Yes | 5 minutes per install (the pilot takes 12 s) and a stated ceiling of 11 registered repos before the lock needs renewing from inside the sweep |
| The semver check was a prefix match: `1.2.3garbage` and `1.2.3/../x` passed, and npm reads the latter as a local path | MINOR | Yes | Full semver match, anchored |
