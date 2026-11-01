# Parity plan: closing gaps against the reference architecture

Goal: before the demo on 2026-11-13, move as many `Gap` and `Partial` rows of the README's security table as possible,
and the four "Known limits", without waiting for Keycard's sandbox egress proxy. Nothing here merges into a running
batch: merge the PRs, `git pull` on the mini only after the current batch ends (ETA 2026-11-02 evening), then rebuild
the image once.

Reviewed by Codex on 2026-11-01 (plan only, no code). Its confirmed findings are folded in below; each item now says
what the orchestrator enforces versus what is a default the worker could override, because the first draft
overclaimed "Meets" in four places.

## Ranked

Effort is lines changed. "Enforced by" says who makes it hold against an untrusted worker.

### 1. Egress allowlist on an internal Docker network (network, and both halves of known limit 1)

The biggest gap, and it does not need Keycard's proxy to close most of the way. The durable part is the network shape;
Keycard's proxy later replaces the proxy container without changing it.

- `docker network create --internal factory-net`: containers on it have no route out and no external DNS. One small
  forward-proxy container (tinyproxy, pinned image) sits on both `factory-net` and the default bridge, with a domain
  allowlist and `FilterDefaultDeny`. The orchestrator starts it once per run with the allowlist for that mode, on the
  fixed `docker run` line, so the task can't change it.
- Per mode: worker → `api.anthropic.com`, `registry.npmjs.org`; judge → `api.openai.com`, `registry.npmjs.org`;
  push → `github.com`. `HTTPS_PROXY`/`https_proxy` env in the container; Claude Code, Codex (reqwest), npm, git and
  curl all honor it. Setting the env is a convenience: with no route out, ignoring it means no network, not open network.
- What this closes: the worker can reach only Anthropic and npm; the judge only OpenAI and npm. Arbitrary HTTPS
  exfiltration is gone. The internet-facing half of known limit 1 is closed.
- What it narrows but does not close: a key read by a test can still leave through an allowed host (npm and OpenAI
  both accept uploads) or through the judge's own findings, which become the next prompt and the PR body. The
  findings path redacts only the literal key today (`factory` line 306); item 9 extends that path too. Credentials
  still live in the container, and the proxy filters by host, not by operation. Those are the Keycard proxy's job.
  The README row moves from Gap to Partial, with those sentences, and the credential-theft half of known limit 1
  stays listed.
- Internal networks on Docker Desktop still reach the bridge gateway and whatever the VM exposes there; "private
  ranges unreachable" is not a claim to make. Say "no route to the internet except the proxy".
- Proxy config: tinyproxy's `Filter` is regex, so anchor each host (`^api\.anthropic\.com$`), set `FilterDefaultDeny
  Yes`, and `ConnectPort 443` only. One proxy container per run, started with the current mode's allowlist and
  replaced between modes, so a worker can't reach the judge's or push's proxy.
- Enforced by: Docker's network namespace. ~40 lines in `factory` plus three `proxy-<mode>.conf` files in the repo.
  Test: a stub case for the `--network` and `-e HTTPS_PROXY` args. The real checks, by hand once on the laptop and
  once on the mini, recorded in `factory.md`: from a worker shell, `curl https://example.com` and `curl
  https://1.1.1.1` fail with the proxy vars unset too, external DNS fails, `curl https://api.anthropic.com` connects,
  port 80 and a lookalike host are refused, and killing the proxy container leaves the worker with nothing. Then a
  real worker round and a real judge round, because the pinned Codex build's transport is the one thing a `curl`
  check doesn't prove.
- Demo: `docker exec` into a running worker, `curl https://example.com` fails, `curl https://api.anthropic.com` connects.
  That is the one-liner that makes the network row concrete.

### 2. Target-repo rulesets so the push token reaches only `factory/**` (identity, known limit 2)

GitHub can't scope the installation token to a branch, but the repo can refuse the App everywhere else.

- Ruleset A, target all branches except `factory/**`: restrict creations, updates and deletions. Bypass list: the
  humans who merge (admins or a team), bypass mode "always". The App isn't on it, so its `contents:write` token can't
  touch `main`, release branches or anyone's feature branch.
- Ruleset B, target `factory/**`: block force pushes, restrict deletions. Revision rounds fast-forward (the push
  container pushes the judged SHA onto the same branch), so no force push is ever needed, and evidence branches can't
  be removed by the App.
- Limits that stay: within `factory/**` the token can push to another task's branch, and branch rulesets don't
  cover tags, so add a tag ruleset (restrict creations, same bypass list) if tags matter in the target repo. Keep the
  existing approval-and-CI ruleset on `main` separate, so the new bypass list doesn't bypass it.
- Cheap companion in `factory`: mint the clone token with `contents:read`, not `contents:write` (only the push
  needs write), and revoke each installation token after its last use (`DELETE /installation/token`).
- Enforced by: GitHub. One step added to "Prepare a target repo", applied to
  `keycard-sandbox/keycard-workshop-platform` after the batch ends. Record the ruleset IDs in `factory.md`.

### 3. Refuse to start on a credential in the input tree or the task (supply chain, PocketOS story)

Screens what the worker will actually get: the base tree and the task text. Codex's corrections are in.

- Scan the tree the worker checks out, not the clone's default checkout: `git -C "$work" grep -I -l -E "$PATTERNS"
  "origin/$from_branch" --` (a tree-ish, so chained bases are covered). `-l` only: file names, never content, so the
  gate can't leak what it found. Distinguish git grep's exit 1 (no match) from 2+ (error → `gate_error`).
- Patterns, fixed in `factory`: `ghp_`, `ghs_`, `github_pat_`, `sk-ant-`, `sk-proj-`, `AKIA[0-9A-Z]{16}`,
  `-----BEGIN [A-Z ]*PRIVATE KEY`, `xox[bpa]-`, `AIza[0-9A-Za-z_-]{35}`. Heuristic: it catches the common shapes, not
  every provider's format (the README should not claim it would have caught PocketOS's Railway token specifically;
  say "a token shaped like these").
- Run the same regex over `instructions` in `cmd_run`, not only in `cmd_lint`, because `factory run` never calls lint.
  One shared function.
- Outcome `credential_in_input`, exit 13, `reason` = the file name. The task-text check runs before any credential
  is minted. The tree check needs the clone, which needs the GitHub token, so it runs after the clone and before
  the Anthropic token and any container. The manifest `outcome` is what identifies a gate decision, never the exit
  number alone (a container can exit 13 too; hardening-plan.md change 2 already says this).
- Not covered: git history and other branches in the mounted clone. The worker can `git log -p`. Scanning history is
  a different tool (gitleaks) and a dependency; note the limit.
- No `allow_secret_patterns` task field: `JOB_SCHEMA` is exactly four keys and three commands validate it. If a target
  repo ever needs it, that is the change to make then.
- Enforced by: the orchestrator. ~35 lines. Test: planted `ghp_` string in the stub base tree → exit 13, no
  `docker run` call recorded. Demo: a demo branch with a fake token, run it, show the refusal and the manifest.

### 4. Manifest-change gate: no PR when a dependency manifest changed without permission (supply chain)

Honest name: this is a PR gate, not package admission. By the time it runs the package has already been installed and
executed in the worker and judge containers. It stops the artifact, not the execution. Admission at install time is
the registry firewall, which stays skipped (below).

- In the existing post-push gate, `git diff --name-only "$base_sha" "$head"` filtered for `package.json`,
  `package-lock.json`, `npm-shrinkwrap.json`, `pnpm-lock.yaml`, `yarn.lock` at any depth (the target is a workspace
  repo with `apps/*` and `packages/*`).
- Permission: the task's `Scope:` section contains `package.json`. Lint only checks the headings' order with a
  regex today; extracting the Scope section is a new ten-line helper that lint and the gate share.
  Scope only, not the whole instructions, because requeue appends judge findings to the text and Out of scope says
  "do not touch package.json". The target repo's task 050a says "the owning package's package.json … for dependencies
  named under Context"; the gate lets that through and the judge still checks which dependencies. Coarse on purpose.
- Outcome `dependency_change`, exit 14, branch still pushed. Precedence as today: worker/push failure first, then
  `gate_error`, then blocked, then this, then conflict. `requeue` gains a line for it, next to `blocked`.
- Enforced by: the orchestrator, on the committed tree. A worker that installs with `--no-save` or restores the
  manifest before committing walks past it. The judge's `npm ci` won't install what the lockfile lacks, but a
  committed test script can fetch and run anything during `npm test`, so the gate bounds the PR's manifests, not
  what executes in the judge.
- ~20 lines. Test: one case with a changed `package-lock.json` and a Scope without `package.json`.

### 5. npm defaults: install scripts off, publication cooldown on (supply chain)

Two env vars on the fixed `docker run` line. They are defaults the worker can override from Bash
(`npm ci --ignore-scripts=false`), and a committed `npm test` script runs whatever it says regardless, so the manifest
records the policy supplied, not behavior verified. The judge runs its own `npm ci` with them as given.

- `-e NPM_CONFIG_IGNORE_SCRIPTS=true`. The target repo's own `.npmrc` already sets `ignore-scripts=true` and its
  `CLAUDE.md` says native modules are optional and rebuilt elsewhere, so the factory default matches what the repo
  already requires of itself. (Its lockfile has five `hasInstallScript` packages, esbuild among them; they install
  without scripts today.) A repo that needs install scripts doesn't necessarily fail at `npm ci`; it fails when the
  module loads, which the judge's test run shows. That repo's CLAUDE.md can't opt out because the judge strips it;
  the opt-out would be a factory flag. None needed yet.
- `-e NPM_CONFIG_BEFORE=<run start minus 7 days>`. Affects version resolution in `npm install`, so a new dependency
  the worker adds resolves to a version at least a week old. `npm ci` installs the lockfile as is; this is not an age
  audit of existing pins.
- Record `npm_ignore_scripts` and `npm_before` in the manifest as supplied policy.
- ~6 lines. README row: supply chain admission moves from Gap to Partial on the strength of items 4 and 5 together.

### 6. Pin the harness, verify the image before starting (supply chain, profile integrity)

- `Dockerfile`: `@anthropic-ai/claude-code@<version>`, the version the mini's image has now (`factory.md` says
  2.1.312 for the 2026-10-29 build; confirm with `docker run --rm --entrypoint claude factory-sandbox --version`).
- `factory`: `IMAGE_ID=sha256:…` constant, compared to `docker image inspect --format '{{.Id}}'`, which is the local
  image config ID the manifest already records (not a registry manifest digest; don't mix them). Mismatch → refuse
  to start. `FACTORY_ALLOW_DIRTY=1` keeps working for development and marks the manifest.
- Rollout is two steps, because the digest must be committed before a clean run: merge the code PR, `git pull`,
  `docker build`, read the ID, open and merge a one-line PR bumping `IMAGE_ID`, `git pull` again. Document it in the
  README under "Install".
- Dropped from the first draft: `docker build --sbom --provenance`. On a local image store the attestations aren't
  inspectable without pushing to a registry, so the claim had no evidence behind it. If the image moves to GHCR
  (build in Actions, pull by manifest digest), add it then; that is also where image signing would go.
- What it pins: the starting image. Bash plus item 1's allowlist still lets the worker fetch from npm at run time;
  items 4 and 5 cover that.
- ~5 lines plus the bump. "Approved, pinned components" moves to Meets for the image and harness.

### 7. Spend cap, pinned model, cost per round in the manifest (inference)

A harness guardrail, not a boundary: the token is in the worker's environment, so a worker that calls the API
directly or starts a second `claude` process is outside the cap. Inference stays Partial until the gateway.

- `claude -p … --model <full model id> --max-budget-usd "$BUDGET_USD"`, both from the orchestrator as `-e`
  (constants; `FACTORY_BUDGET_USD` overrides, default 10). The cap is client-side estimated spend and can overshoot,
  so a five-round task is bounded at roughly 5 × budget, not exactly. A full model ID, not an alias, is the pin.
- Codex: `-m <full model id>`. No spend flag. Set hard spend limits (not alerts) on the Anthropic `factory` workspace
  and the OpenAI project in their consoles; record both in `factory.md` as the per-workspace backstop.
- Cost record: tag every wrapped log line with `mode` and `round` (two `--arg`s on the existing jq wrapper), then pull
  each worker round's final `result` event (`total_cost_usd`, `num_turns`, `duration_ms`) into
  `manifest.worker.rounds[]`. A round with no `result` line (killed, crashed) records `cost_usd:null`, not zero.
  `factory report` sums what is known and marks unknowns. Worker-side only; the judge's cost isn't visible to us.
  Container output is untrusted, so the field is labelled `reported_cost_usd`.
- A worker that exits non-zero on the cap fails the round under `set -eu` before the safety-net commit; the round's
  edits are lost, as for any worker failure today. The log keeps the `result` line that says why.
- ~25 lines. Demo: `./factory report` with a cost column; `model` and `budget_usd` in the manifest.

### 8. Log pipeline fails closed, evidence protected (observability)

Two cheap things Codex pointed at that the first draft missed.

- `run_container` takes only `PIPESTATUS[1]` (docker). If the redaction loop or `jq` fails, the log is incomplete
  while the round looks fine. Capture the whole array in one assignment (`ps=("${PIPESTATUS[@]}")`; reading one
  element resets it). A non-zero log stage can't be folded into the container's status: the judge path turns any
  status into "no verdict" (`jstatus=$status; status=0`) and a later worker failure still pushes the last judged
  commit. So it is its own state: `evidence_failed=1`, manifest `outcome:"evidence_error"`, no further container
  starts, no push, no PR, exit 12, kept through finalization. ("A run that can't produce the record fails closed.")
- `chmod 700 "$RUNS"` (the directory exists on the mini already, so not `mkdir -m`) and `umask 077` around the run
  directory, so new evidence isn't world-readable. Existing run directories get a one-time `chmod -R go-rwx`.
- `curl --max-time` on every host-side call (Keycard, Anthropic, GitHub): the container watchdog doesn't cover them.
- ~15 lines. Tests: a failing `jq` in a worker round, in a judge round, and in a revision round, each ending with
  `outcome:"evidence_error"` and no push.

### 9. Redaction: token shapes, not just the literal (observability, known limit 4)

Redaction is a mitigation, never a boundary; item 1 narrows where a token can go, and this narrows what the
factory itself publishes. Two cheap additions close the "encoded" half of the limit:

- Redact the base64 of the bare token and its URL-encoded form, next to the Basic-auth form already covered.
- Redact by shape as well as by value: `sk-ant-[A-Za-z0-9_-]{20,}`, `ghs_[A-Za-z0-9]{36}`, `sk-proj-[A-Za-z0-9_-]{20,}`.
  A token the orchestrator never saw (the judge echoing its own key in a different form, a token minted inside the
  container) is caught by shape.
- Apply it on every path that leaves the run, not only the stream loop: the judge's findings (next prompt, PR body,
  `judge-<n>.md`), the blocked `reason`, and the notification text. One `redact` function, called in each place.
- Split tokens stay uncaught. Say so.
- ~12 lines. Tests: a base64 token in stub output is `[REDACTED]`; a shaped token in a stub verdict is redacted in
  the PR body the stub records.

### 10. Provenance block in the PR body (supply chain, "outputs carry provenance")

The manifest doesn't hold everything the block needs yet. Add `claude_code_version`, `codex_version` (both read from
the image at run start with `docker run --entrypoint`), `model`, and items 5 and 7's fields, then render from a
snapshot taken right before `open_pr` (the manifest's `final_sha` is written after it). Block: run ID, factory
commit, image ID, harness versions, model, judge rounds and verdict, npm policy, Keycard zone, the pushed commit.
It is review metadata, not an attestation: unsigned, and "which checks passed" is still the judge's narrative, not
structured results. ~15 lines.

### 11. Hash ledger over run records (observability)

Tamper-evidence against the host operator is outside the paper's scope, so a checksum ledger is the right size,
with its limit stated: an unanchored chain can't show that a whole suffix was rewritten.

- One line per finalization, appended by whoever finalizes: `cmd_run`'s finalize, `cleanup` on an early exit, the
  batch's repair of a killed run, and `factory stop` after the fact. Each line: run ID, event, sha256 of the manifest,
  of `log.jsonl`, and of every `judge-*.md`, and the previous line's hash. The first draft hashed only two files, which
  is why its "edit a judge file" demo wouldn't have worked.
- A ledger write failure after the PR is open is logged and the run's exit status stands; the PR isn't withdrawn over
  a bookkeeping failure, and `report` shows the run as unsealed.
- `factory report` recomputes and marks mismatches. ~15 lines.

### 12. Harness deny rules for the worker (sandbox, defense in depth)

Real in headless mode (deny rules win over `--allowedTools`), but the harness is not the sandbox: `node -e 'fetch(…)'`
walks around a denied `curl`. Keep it in the Partial column.

- Orchestrator mounts a `worker-settings.json` read-only (`-v …:/etc/factory/settings.json:ro`,
  `--settings /etc/factory/settings.json`), so the worker can't edit it in its writable HOME. Deny `Bash(curl *)`,
  `Bash(wget *)`, `Bash(npm publish*)`, `Bash(git push*)`. Not `npm install`: item 4 permits authorized dependency
  changes and this would block the cooperative path.
- The worker's repo can still carry `.claude/settings.json` and hooks that Claude Code loads; deny rules from the
  mounted file still apply, but hooks run. Note it; stripping them is the judge's treatment, not yet the worker's.
- ~10 lines.

## The Keycard client secret (known limit 3)

Four options, checked against the SDK source and docs.keycard.ai on 2026-11-01:

- **`keycard auth` on the mini.** A user identity: OIDC tokens in the system keychain, refreshed. Not a file in
  `~/factory-secrets`, but still a long-lived credential on the machine, and it makes every grant read "Kim did this"
  instead of "the factory did this". A Level 2 factory is supposed to have its own identity. A restricted group with a
  Cedar `principal in Keycard::Group::"factory"` permit would bound what that user can reach, but it is still a human
  principal standing in for a service. Don't.
- **Workload identity federation.** Supported for any issuer with an OIDC discovery document: register a Provider
  with the issuer URL, add a Workload Identity credential to the Application matching `iss` and `sub`. The mini has no
  platform that issues it a token. The one that fits is GitHub Actions on a self-hosted runner on the mini: the job's
  OIDC token (`sub` = `repo:kmaida/software-factory:ref:refs/heads/main`) is the Application's assertion, no static
  secret anywhere, and the factory's execution layer becomes CI/CD, which is exactly the reference architecture's Level
  2 column. It changes how batches start and run (a workflow, not a shell command), so it is a post-demo project.
- **private_key_jwt (RFC 7523). Supported, verified in source on 2026-11-01.** The management API has
  `POST /zones/{zoneId}/application-credentials` with `{application_id, type: "public-key", jwks_uri}`
  (keycard-api `api/openapi.yaml`, `iam_ApplicationCredentialCreatePublicKey`). The STS maps a `public-key`
  credential to `token_endpoint_auth_method: private_key_jwt` (svc-sts `packages/a3/src/client.js`) and verifies the
  assertion against the keys at that `jwks_uri` (svc-sts `src/auth/oauth/client/assertion/jwt.js`,
  `handlePrivateKeyJwt`): `iss` and `sub` both equal the credential's identifier (the client ID), `aud` is the token
  endpoint URL as requested, signature from the JWKS. Then `grant_type=client_credentials` proceeds as the
  Application, same as today.
  - What the factory does: `keycard_token` builds the assertion the way `mint_github_token` already builds the GitHub
    App JWT (`b64url`, `openssl dgst -sha256 -sign`), and posts
    `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer` plus `client_assertion` instead of
    the Basic-auth secret. ~15 lines, one new file in `~/factory-secrets` (`keycard_key.pem`, 0400) replacing
    `keycard_client_secret`. `jti` per request, `exp` 5 minutes.
  - Where the JWKS lives: Keycard fetches `jwks_uri` over HTTPS and the mini isn't reachable, so publish
    `docs/jwks.json` from this repo via GitHub Pages (the repo is public, `main` is under a ruleset; Pages isn't on
    yet). A public key isn't secret. The thing to protect is then "who can change that file", and the answer is a
    reviewed PR to `main`, which is the same bar as changing the factory itself.
  - Why it is better than the secret: the key is never transmitted, so there is nothing on Keycard's side to leak or
    replay, and rotation is a PR that swaps the JWKS entry plus a new PEM on the mini. It is still a file on disk.
  - Do it with the Secure Enclave from the start, not as a phase 2. The STS keyring imports EC JWKs with the curve
    they name and the verifier selects ES256 from the key (svc-sts `src/keyring.js`, `src/tokens/jwt/verifier.js`),
    so a P-256 key works.
  - The signer uses CryptoKit, not the SecKey export API (which refuses enclave keys; `SecKey.h` says so):
    `SecureEnclave.P256.Signing.PrivateKey()` to generate, its `dataRepresentation` written to `~/factory-secrets/`
    (an opaque blob only this machine's enclave can use: no keychain, no entitlements, the same design as
    age-plugin-se), `PrivateKey(dataRepresentation:)` to load, `signature(for:).rawRepresentation` for the 64-byte
    `r||s` JWS wants (no DER conversion), and `publicKey.x963Representation` for the `pubkey` subcommand that prints
    the JWK for `docs/jwks.json`. The default access control in the macOS SDK is
    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` with no flags: no biometric, no presence, usable after the
    mini has been unlocked once since boot. ~40 lines of Swift, compiled and ad-hoc signed on the mini with
    `swiftc`. `keycard_token` calls it where `mint_github_token` calls `openssl dgst`, and a signer failure aborts
    before the token request.
  - The credential's `identifier` is the OAuth client ID and is generated when omitted, so the cutover writes the
    new identifier into `~/factory-secrets/keycard_client_id`; the old one is the password credential's and would
    be rejected as the wrong credential type. `application_id` is the Application's Keycard ID, not its URN.
  - Cutover without a fallback branch: an Application can hold more than one credential. Add the `public-key`
    credential, switch `keycard_token`, run one task that exercises all three resource grants (Anthropic exchange,
    the Codex key, the GitHub App key), then delete the client-secret credential. If the enclave path fails on the
    mini, the secret still works until it is deleted.
  - What it buys over a client secret or an RSA PEM: the private key cannot leave the mini, not by `cat`, not by
    backup. A captured assertion is usable for its five-minute lifetime (the STS checks `exp`; the files read don't
    show a `jti` replay cache), which is the exposure of any signed assertion over TLS. That is the one-sentence demo
    line for the identity row: the factory proves who it is with a key that never leaves the machine.
- **Keep the secret, shrink its blast radius.** Already true: it never enters a container, and the Application's
  permits are only the three factory resources. The ref arch's own text says the client-secret path "is what
  remains" for a machine that can't attest to itself.

Recommendation: private_key_jwt with a Secure Enclave key, this week, as its own PR (`se-sign.swift`,
`keycard_token`, `docs/jwks.json`, the README's secrets step). GitHub Actions federation stays on the post-demo list
as the way to have no key on the mini at all.

### Prerequisite: prototype the signer on the laptop (item 13, gates the Keycard PR)

The PR is not written until this passes, on the laptop, with no Keycard involved. Each step has a check that fails if
the assumption behind it is wrong.

1. `swiftc se-sign.swift` compiles; `codesign -s - se-sign` succeeds; `codesign -d --entitlements - se-sign` shows
   none. Establishes the toolchain and that the binary carries no entitlements, so step 2 is the real test.
2. `se-sign keygen <blob>` creates the key and writes the blob. Then, in a fresh process, `se-sign sign <blob>`
   signs. Fails if an entitlement-free CLI can't create or restore an enclave key. Device binding: copy the blob to
   a second Mac and run `sign` there; it must fail at load or at sign (loading alone may defer validation). A
   corrupted blob failing proves nothing about binding, so it isn't the check.
3. `se-sign pubkey <blob>` prints the JWK (`kty: EC`, `crv: P-256`, `x`, `y`, `kid`, `use: sig`, `alg: ES256`).
   Check: the public key derived from the restored enclave key, exported as PEM, loads in `openssl ec -pubin` and
   its coordinates match the JWK. Loading the private blob as PEM must fail.
4. `se-sign sign <blob> < input` writes exactly 64 bytes. Verify independently with `node`:
   `crypto.verify('sha256', input, {key, dsaEncoding: 'ieee-p1363'}, sig)` must return `true` on ten different
   inputs (covers high-bit `r`/`s` values that a bad padding step would break). No round trip through our own code.
5. Build the full client assertion (`iss`/`sub` = a test client ID, `aud` = a test URL, `jti`, `iat`, `exp` +300 s)
   with the same `b64url` helper `factory` uses, sign it, and verify header, signature and claims (`aud`, `exp`,
   `iss === sub`) with `jose` in `node` against the JWK from step 3. This is the artifact Keycard will see.
6. Session state: the blob still signs after a reboot and first unlock, and from an SSH session while the console
   is locked and while no user is logged in at the console. The mini is driven by hand at a logged-in session today,
   but the result goes in `factory.md` so the unattended case is known, not assumed.
7. Through the caller: `keycard_token` with a missing blob, a corrupt blob and a signer that exits non-zero must
   abort before any HTTP request (`test-factory.sh` case with a stub `se-sign`).
8. Record the laptop's result in `factory.md` (macOS version, chip, exact commands). The mini repeats 1, 2, 4, 6 and
   7, and verifies its real JWK and a real assertion with the step 5 script, since those are the production
   artifacts.

Unknowns the prototype settles: entitlement-free enclave access from a CLI, the signature encoding, and the session
states in which signing works. Unknowns it does not settle: Keycard's fetch of the GitHub Pages `jwks_uri` (the
schema says `uri`, the keyring's fetch, redirect and cache behavior weren't read) and the exact `aud` string, which
the first real token request on the mini settles, with the client secret still in place as the fallback.

Zone side, after the prototype: enable GitHub Pages on the repo for `docs/`, commit `docs/jwks.json`, then one
management-API call to add the `public-key` credential to `urn:factory:mini` with that `jwks_uri`; delete the
client-secret credential after the first clean run.

## Skipped on purpose

- **Credentials at the proxy, per-request authorization, model gateway.** Keycard's proxy. Item 1 gives it the
  network to plug into.
- **Per-agent Keycard identity.** Codex is right that "theater" was too strong: separate principals get separate
  policies and revocation. But until credentials are attached outside the container, the orchestrator is the only
  thing that authenticates, and the audit log should say so. Do it with the proxy. What can be recorded now, and
  should be: `role` (worker, judge, push) on every log line (item 7 does this) and the requester on the manifest
  (the batch's operator, from `id -un` and `hostname`, labelled `launcher`, since task files aren't committed and
  have no author and `$USER` is just an env var).
- **Registry proxy (Verdaccio, Socket).** Real package admission, and item 1's internal network is where it would
  sit. Host filtering (item 1) and version admission with scanning are different controls; the README should keep
  saying admission is a gap. Revisit after the demo if the Keycard proxy doesn't cover package admission.
- **Credential-free check container.** Item 1 narrows where a stolen judge key can go but doesn't stop a test from
  reading it; moving the repo's test run away from the key is the complete fix and is worth doing, but it is a
  second container per round and a prompt change for the judge. After the demo, and listed as open in the README
  until then.
- **MicroVM isolation.** Hosting decision, not a code change. The README already says the VM is shared.
- **Commit signing.** The ref arch asks for provenance, not signed commits. Item 10's block is unsigned metadata and
  the README should call it that.

## Order for the week

Until the batch report lands (2026-11-02 evening) nothing touches the mini, the workshop repo's rulesets, the
zone's credentials, or the console spend limits. Laptop work only:

0. Two prototypes on the laptop, independent of each other: item 13 (the signer) and item 1's network (an
   `--internal` network, the proxy container, the by-hand checks listed under item 1, then a real worker round and
   judge round from the laptop). Both have unknowns that only running settles.
1. `egress` PR (item 1), `supply-chain` PR (items 3, 4, 5), `pins-budget-log` PR (items 6, 7, 8, 9), `records` PR
   (items 10, 11, 12 if there is time), `keycard-key` PR (`se-sign.swift`, `keycard_token`, `docs/jwks.json`, README).
   All touch `factory` and the README, so land them one at a time in that order and rebase the next.

After the report, on the mini, in this order, each with a real run before the next:

2. Rulesets on the workshop repo (item 2), console spend limits, GitHub Pages for `docs/` (needed before the
   first public-key token request). `git pull`, build, bump `IMAGE_ID` by PR, pull again.
3. Egress rehearsal with the existing identity: the by-hand checks, then the two demo tasks from `docs/demo.md`.
4. Keycard cutover: compile and keygen on the mini, add the `public-key` credential, switch, one full run, delete
   the client secret. Gated on its own prototype and on step 3 having passed, so an identity failure is never
   confused with a network one.
5. Two full rehearsal days before 2026-11-13 with everything in place, and a known way back (re-add the secret
   credential, `git checkout` the previous factory commit) written in `docs/demo.md`.

README table after this plan: Network Gap → Partial (allowlist by host, credentials still inside). Supply chain
admission Gap → Partial (lockfile gate, cooldown default, no registry). Pinned components Partial → Meets.
Credentials in inputs: new Partial row (tree and task screened by shape; history not). Inference Gap → Partial
(harness cap, pinned model, no gateway). Observability: tamper-evidence Partial with the ledger and its limit stated;
fail-closed logging Meets. Known limits: 1 closed for arbitrary egress and still open for theft through an allowed
host or the findings; 2 closed except within `factory/**` and tags; 3 closed (the key can't leave the mini; the
blob on disk is the remaining artifact); 4 narrowed to split tokens.

Reviewed twice by Codex (2026-11-01). Second-round claims checked and rejected: that the STS keyring can't import
EC keys (it does, `src/keyring.js`); that `.privateKeyUsage` is required (it is for the SecKey path; CryptoKit's
default access control has no flags and signs). Everything else it flagged is reflected above.
