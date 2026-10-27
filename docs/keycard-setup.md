# Keycard setup for the factory

Verified against the using-keycard skill (snapshot 2026-10-26) and corrected 2026-10-26 after a first attempt assumed one GitHub provider per role. Linear added 2026-10-27 (the last unbrokered credential). Two facts shape everything:

1. **A zone has one provider per issuer.** Providers are keyed by issuer URL, so one GitHub App's client id/secret backs every GitHub resource in the zone, and one Linear OAuth app backs every Linear resource. One brokered credential of each kind locally.
2. **On the CLI path the principal is the Keycard CLI app + Kim for every process** (gotchas.md:201). `keycard.toml` selects resources, not an application identity.

So Keycard gives the factory: credentials brokered into each process with nothing on disk, every exchange audited on behalf of Kim, and hard failure when consent is missing (`agent exec`). It does **not** give per-role separation on one machine. Separation lives in *where code runs*:

| Capability | Where | Credential |
|---|---|---|
| push `factory/*`, open/update PR, read PRs, variables, Actions artifacts and commit statuses | local worker / dispatch | the one brokered GitHub token (`urn:github:factory`) |
| read the queue, move issues between states, assign, comment | local worker / dispatch, only via `scripts/linear.sh` | the one brokered Linear token (`urn:linear:factory`) |
| post `factory/judge-*` statuses | **GitHub Actions** (judge job) | the workflow's own `GITHUB_TOKEN` |
| merge | GitHub Actions (merge job) | merge App token from Actions secrets |

A local process can never post a judge status or merge because the local token has neither permission and the secrets live only in Actions.

Every local process, dispatch included, runs as `keycard agent exec --config keycard.toml --zone <zone> -- <command>`. The two `[[credentials.default]]` entries in `keycard.toml` become `GH_TOKEN` and `LINEAR_TOKEN` in that process and nowhere else. If a consent is missing or a token is rejected, `agent exec` or `scripts/linear.sh` exits non-zero with the reason; the sweep never degrades to "nothing to do".

## Kim-only steps (one time)

1. **Two GitHub Apps** (https://github.com/settings/apps; names are global, prefix them):
   | App | Permissions | Used by | Credential to keep |
   |---|---|---|---|
   | `kmaida-factory` | Repository: Contents write, Pull requests write, Metadata read, Variables read, **Actions read-only, Commit statuses read-only** (the dispatcher reads judge statuses with `gh api .../commits/<sha>/status` and downloads judge transcripts with `gh run download`; read-only keeps the 403 on posting a status). **Account: Email addresses read-only (required: Keycard resolves the user through GitHub's `/user/emails`; without it every authorize naming a GitHub resource fails with `server_error` before GitHub is ever shown)** | local worker + dispatch via Keycard | client ID + client secret → Keycard |
   | `kmaida-factory-merge` | Contents: write, Pull requests: write | merge job only | App ID → repo variable `FACTORY_APP_ID`; private key → repo secret `FACTORY_APP_PRIVATE_KEY` |
   Callback URL for `kmaida-factory` = the zone's Redirect URL; webhook off; "Expire user authorization tokens" on. Install both on the pilot repo (Only select repositories). No private key for `kmaida-factory`; no client secret needed for `kmaida-factory-merge`. Adding a permission to an installed App needs the installation re-approved (GitHub emails the owner; or Settings → Applications → Installed GitHub Apps → Configure).
2. **One Linear OAuth app** (Linear → Settings → API → OAuth applications → Create; https://linear.app/settings/api):
   | App | Setting | Used by | Credential to keep |
   |---|---|---|---|
   | `kmaida-factory` | Callback URL = the zone's Redirect URL (the same one the GitHub App uses). Public: off. Actor: user (default; the factory writes as Kim, like its GitHub pushes). No webhook. Scopes are not set on the app; Keycard requests them per resource (next step). | local worker + dispatch via Keycard, only through `scripts/linear.sh` | client ID + client secret → Keycard |
   Nothing to install: a Linear OAuth app in the `keycardlabs` workspace can act on any project Kim can.
3. **Keycard**: Resources → add GitHub from the catalog once, with `kmaida-factory`'s client id/secret (this creates the zone's GitHub provider). Identifier `urn:github:factory`. Credential provider: that GitHub provider. Provided by: nobody. Scopes: default.
   Then Resources → add Linear from the catalog once, with the Linear OAuth app's client id/secret (this creates the zone's Linear provider; plan-my-today's zone has its own, zones do not share providers). Identifier `urn:linear:factory`. Credential provider: that Linear provider. Provided by: nobody. Scopes: `read` and `write` (`write` covers `issueUpdate` and `commentCreate`; `comments:create` alone cannot change state). Linear access tokens last 24 h with a refresh token; Keycard refreshes them, which is what the MCP plugin could not do unattended.
4. **Consent**, once per resource, from a browser machine signed in to Keycard as Kim:
   ```bash
   keycard auth resource --zone 1jgewf106fax3oaf70vyykwj2i urn:github:factory
   keycard auth resource --zone 1jgewf106fax3oaf70vyykwj2i urn:linear:factory
   ```
5. **Repo**: `gh variable set FACTORY_PAUSED -b false -R kmaida/plan-my-today`; `FACTORY_APP_ID` and `FACTORY_APP_PRIVATE_KEY` from step 1; judge keys as repo secrets `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` (API billing for judge runs; local worker/dispatch stay on subscription logins).
6. **Branch protection on `main`**: require the `ci / test` check; require up to date; restrict pushes to `kmaida-factory-merge`. Do not make judge statuses required checks; the merge gate requires them itself.
7. **Verify** (on the mini, in its GUI session, where the Keycard login lives):
   ```bash
   keycard agent exec --config keycard.toml --zone 1jgewf106fax3oaf70vyykwj2i -- gh api user --jq .login
   keycard agent exec --config keycard.toml --zone 1jgewf106fax3oaf70vyykwj2i -- gh api -X POST repos/kmaida/plan-my-today/statuses/$(git -C ~/Documents/Development/plan-my-today rev-parse origin/main) -f state=success -f context=factory/judge-claude   # must 403
   keycard agent exec --config keycard.toml --zone 1jgewf106fax3oaf70vyykwj2i -- scripts/linear.sh issues P-KIM-206 | jq '.project.name, (.issues | length)'   # "Plan My Today", a count
   keycard agent exec --config keycard.toml --zone 1jgewf106fax3oaf70vyykwj2i -- scripts/dispatch.sh    # one brokered sweep by hand
   ```
   Both `keycard credential read` exchanges (`urn:github:factory`, `urn:linear:factory`) then appear in the zone's audit log. Afterwards disable the Linear MCP plugin so nothing on the mini can fall back to a personal Linear login: `claude plugin disable linear@claude-plugins-official`.

## Not brokered

- Model logins locally: native subscriptions. Brokering `ANTHROPIC_API_KEY` would silently move Claude Code to API billing.
