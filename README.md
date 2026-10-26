# factory

Linear issue → worktree worker → two-model judge → merge controller in CI. Keycard brokers per-role credentials.

- `skills/factory:factory-onboard` — one-time per repo: preflight, setup PR, registry row.
- `skills/factory:factory-dispatch` — one idempotent sweep: claim, start workers, judge green PRs, reset stale runs.
- `skills/factory:factory-worker` — implement one issue, open PR, exit.
- `skills/factory:factory-judge` — Claude + Codex refute the PR at its exact SHA, post commit statuses.
- `scripts/risk-gate.sh` — deterministic low/review decision, run in CI from the base commit. `scripts/test-risk-gate.sh` is its check.
- `templates/factory-merge.yml` — the only merge path.
- `keycard.toml` — the single Keycard config for local processes (one GitHub provider per zone).

Run: `KEYCARD_ZONE=<zone> claude -p "/factory:factory-dispatch" --plugin-dir <this dir>` (or install the plugin and drop the flag). Pause: `gh variable set FACTORY_PAUSED -b true -R owner/repo`.
