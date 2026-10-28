# factory

Linear issue → worktree worker → two-model judge → merge controller in CI. Keycard brokers per-role credentials.

## Against the agentbaseline.org software-factory reference (Level 1)

Have: versioned profile (`.factory/policy.json` + CLAUDE snippet, read from the base commit); approval policy (Kim merges; `auto_merge` opt-in); no local process holds a credential (Keycard brokers `GH_TOKEN` and `LINEAR_TOKEN` into dispatch and workers alike; `scripts/linear.sh` is the only Linear client, `scripts/pr.sh` opens the worker's PR over REST because `gh` cannot verify TLS inside the sandbox, and factory Claude processes run with no MCP servers at all); judge and merge run where no local process has their tokens, from workflow definitions a PR cannot change (`pull_request_target`), with every secret in a default-branch-only GitHub Environment so a PR-added workflow gets none of them; PR code in the judge runs only in throwaway containers, with no network during checks; judge verdicts are HMAC-signed and the merge gate verifies the signature, never the status name; the gate refuses a PR retargeted off the default branch before reading from it; policy changes force review; deterministic gate plus two models, never an LLM judge alone; run id in Linear comment, PR body, and Keycard audit; budgets per run (turns + wall clock); pause switch; worker shell egress limited to the allowlist in `worker-settings.json` under `auto` mode, with the npm registry explicitly denied (dispatch runs `npm ci --ignore-scripts` from the base lockfile before the worker starts, so the one-command path to fetching and running a registry package is closed; git and tarball URLs on allowed hosts are not); the records that are independent of the worker are named, and the rest is treated as context: independent are the signed `factory/judge-*` entries in the append-only commit status list, the judge and merge run logs from `main`, the merge App's commits, and Keycard's exchange log; Linear comments, the PR body and `~/.factory/logs` are written by the same identity as the worker, and dispatch attaches the worker log to the Linear issue at exit labeled as such.

Plan for the rest, validated against Codex: `docs/baseline-plan.md`. Not yet: a sandbox the agent can't escape (the worker is a Claude Code seatbelt sandbox on the developer's machine, not a microVM); a true default-deny egress proxy outside the agent (the Keycard egress proxy); supply-chain admission for packages (today workers cannot change lockfiles or manifests at all, which sidesteps it); a run id that an independent component vouches for (it is minted by dispatch and carried only by the records dispatch and the worker write; the independent records identify a run by head SHA, judge run id and exchange timestamps instead).

- `skills/factory:factory-onboard` — one-time per repo: preflight, setup PR, registry row.
- `skills/factory:factory-dispatch` — one idempotent sweep: claim, start workers, judge green PRs, reset stale runs.
- `skills/factory:factory-worker` — implement one issue, open PR, exit.
- `skills/factory:factory-judge` — Claude + Codex refute the PR at its exact SHA, post commit statuses.
- `scripts/risk-gate.sh` — deterministic low/review decision, run in CI from the base commit. `scripts/test-risk-gate.sh` is its check.
- `templates/factory-merge.yml` — the only merge path.
- `scripts/linear.sh` — the factory's whole Linear surface: list a project's `factory` issues, read one, set state by name, assign, comment, over Linear's GraphQL API with the brokered `LINEAR_TOKEN`.
- `scripts/dispatch.sh` — sweep entrypoint: preflight (registry, brokered tokens, every registered project readable), then the dispatch skill. Fails loudly instead of reporting "nothing to do".
- `keycard.toml` — the single Keycard config for local processes (one provider per issuer per zone: `urn:github:factory` → `GH_TOKEN`, `https://api.linear.app` → `LINEAR_TOKEN`). Setup in `docs/keycard-setup.md`.

Run: `KEYCARD_ZONE=<zone> keycard agent exec --config keycard.toml --zone <zone> -- scripts/dispatch.sh` from this directory. The dispatch skill runs with `--permission-mode bypassPermissions`: under `auto`, the permission classifier refuses to spawn the worker subprocess and the sweep stops to ask. Workers themselves run under `auto`. Pause: `gh variable set FACTORY_PAUSED -b true -R owner/repo`.

## Local files

Three files are gitignored and live only on the host: `keycard.toml` (org and zone ids plus the two `[[credentials.default]]` entries, `GH_TOKEN` and `LINEAR_TOKEN`), `templates/ai.keycard.factory.dispatch.plist` (the LaunchAgent that runs `scripts/dispatch.sh` under `keycard agent exec`), and `docs/keycard-setup.md` (the Keycard, GitHub App and Linear setup steps). They hold identifiers and host paths, not secrets; they stay out of the repo so the public history describes the design, not one machine. Their copies for the mini, the install commands, and the host notes that `docs/mini.md` replaces with placeholders live in the private repo [kmaida/factory-host](https://github.com/kmaida/factory-host).

## Mini

The always-on host is a Mac mini running the dispatcher as a dedicated non-admin macOS user from a LaunchAgent every 30 minutes. Versions, logins, paths, the plist, and the FileVault tradeoff are in `docs/mini.md`; the plist is `templates/ai.keycard.factory.dispatch.plist`.
