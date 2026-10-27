# factory

Linear issue → worktree worker → two-model judge → merge controller in CI. Keycard brokers per-role credentials.

## Against the agentbaseline.org software-factory reference (Level 1)

Have: versioned profile (`.factory/policy.json` + CLAUDE snippet, read from the base commit); approval policy (Kim merges; `auto_merge` opt-in); no local process holds a credential (Keycard brokers `GH_TOKEN` and `LINEAR_TOKEN` into dispatch and workers alike; `scripts/linear.sh` is the only Linear client, and factory Claude processes run with no MCP servers at all); judge and merge run where no local process has their tokens; policy changes force review; deterministic gate plus two models, never an LLM judge alone; run id in Linear comment, PR body, and Keycard audit; budgets per run (turns + wall clock); pause switch; worker shell egress limited to the allowlist in `worker-settings.json` under `auto` mode.

Not yet (Phase 3): a sandbox the agent can't escape (the worker is a Claude Code seatbelt sandbox on the developer's machine, not a microVM); a true default-deny egress proxy outside the agent (the Keycard egress proxy); supply-chain admission for packages (today workers cannot change lockfiles or manifests at all, which sidesteps it); tamper-evident local run logs (GitHub Actions logs and the Keycard audit log are; `~/.factory/logs` is not).

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

## Mini

The always-on host is a Mac mini running the dispatcher as a dedicated non-admin macOS user from a LaunchAgent every 30 minutes. Versions, logins, paths, the plist, and the FileVault tradeoff are in `docs/mini.md`; the plist is `templates/ai.keycard.factory.dispatch.plist`.
