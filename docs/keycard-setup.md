# Keycard setup for the factory

Verified against the using-keycard skill (snapshot 2026-10-26) and corrected 2026-10-26 after a first attempt assumed one GitHub provider per role. Two facts shape everything:

1. **A zone has one GitHub provider.** Providers are keyed by issuer URL, so one GitHub App's client id/secret backs every GitHub resource in the zone. One brokered GitHub credential locally.
2. **On the CLI path the principal is the Keycard CLI app + Kim for every process** (gotchas.md:201). `keycard.toml` selects resources, not an application identity.

So Keycard gives the factory: credentials brokered into each process with nothing on disk, every exchange audited on behalf of Kim, and hard failure when consent is missing (`agent exec`). It does **not** give per-role separation on one machine. Separation lives in *where code runs*:

| Capability | Where | Credential |
|---|---|---|
| push `factory/*`, open/update PR, read PRs and variables | local worker / dispatch | the one brokered GitHub token (`urn:github:factory`) |
| post `factory/judge-*` statuses | **GitHub Actions** (judge job) | the workflow's own `GITHUB_TOKEN` |
| merge | GitHub Actions (merge job) | merge App token from Actions secrets |

A local process can never post a judge status or merge because the local token has neither permission and the secrets live only in Actions.

## Kim-only steps (one time)

1. **Two GitHub Apps** (https://github.com/settings/apps; names are global, prefix them):
   | App | Permissions | Used by | Credential to keep |
   |---|---|---|---|
   | `kmaida-factory` | Contents: write, Pull requests: write, Metadata: read, Variables: read | local worker + dispatch via Keycard | client ID + client secret → Keycard |
   | `kmaida-factory-merge` | Contents: write, Pull requests: write | merge job only | App ID → repo variable `FACTORY_APP_ID`; private key → repo secret `FACTORY_APP_PRIVATE_KEY` |
   Callback URL for `kmaida-factory` = the zone's Redirect URL; webhook off; "Expire user authorization tokens" on. Install both on the pilot repo (Only select repositories). No private key for `kmaida-factory`; no client secret needed for `kmaida-factory-merge`.
2. **Keycard**: Resources → add GitHub from the catalog once, with `kmaida-factory`'s client id/secret (this creates the zone's GitHub provider). Identifier `urn:github:factory`. Credential provider: that GitHub provider. Provided by: nobody. Scopes: default.
3. **Consent**, once, from a browser machine:
   ```bash
   keycard auth resource --zone 1jgewf106fax3oaf70vyykwj2i urn:github:factory
   ```
4. **Repo**: `gh variable set FACTORY_PAUSED -b false -R kmaida/plan-my-today`; `FACTORY_APP_ID` and `FACTORY_APP_PRIVATE_KEY` from step 1; judge keys as repo secrets `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` (API billing for judge runs; local worker/dispatch stay on subscription logins).
5. **Branch protection on `main`**: require the `ci / test` check; require up to date; restrict pushes to `kmaida-factory-merge`. Do not make judge statuses required checks; the merge gate requires them itself.
6. **Verify**:
   ```bash
   keycard agent exec --config keycard.toml --zone 1jgewf106fax3oaf70vyykwj2i -- gh api user --jq .login
   keycard agent exec --config keycard.toml --zone 1jgewf106fax3oaf70vyykwj2i -- gh api -X POST repos/kmaida/plan-my-today/statuses/$(git -C ~/Documents/Development/plan-my-today rev-parse origin/main) -f state=success -f context=factory/judge-claude   # must 403
   ```

## Not brokered

- Linear: workers and dispatch use Claude Code's Linear MCP (its own OAuth as Kim). Replacing MCP calls with `curl` + a brokered token is possible later.
- Model logins locally: native subscriptions. Brokering `ANTHROPIC_API_KEY` would silently move Claude Code to API billing.
