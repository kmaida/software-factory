# Spike: the worker step on OpenSandbox and agentgateway

Can the worker run with no Anthropic credential in its container? This spike runs Claude Code from the `factory-sandbox` image inside an [OpenSandbox](https://github.com/opensandbox-group/OpenSandbox) sandbox whose only route to a model is [agentgateway](https://agentgateway.dev), which holds the token and attaches it. Keycard stays the issuer. Nothing here is called by `factory`.

```bash
./spike.sh
```

That is mock mode: a stand-in for `api.anthropic.com` and a made-up token, so it costs nothing and needs no secret. `./spike.sh real` mints the token the way `factory` does and uses the real API; it needs `FACTORY_SECRETS_DIR`, and that variable alone never selects it. It needs `docker`, `uv`, `jq`, `openssl` and the `factory-sandbox` image.

## What the script checks

Mock mode, last run 2026-11-17 on a Mac with OrbStack (Docker 29.8.2, arm64). The pins are in `spike.sh`: opensandbox-server 1.2.1, egress sidecar and execd `release-1.2.1`, agentgateway v1.7.0. The image carries Claude Code 2.1.316.

```
PASS  runs as the image's unprivileged user
PASS  gateway answers the run key
PASS  gateway refuses a model call with no key  [401]
PASS  gateway refuses a model call with a wrong key
PASS  npm registry reachable
PASS  api.anthropic.com refused (direct, by name)  [sandbox 000, control 404]
PASS  example.com refused  [sandbox 000, control 200]
PASS  unlisted IP refused (1.1.1.1)  [sandbox 000, control 301]
PASS  gateway refused on a port the rule does not name (15021)  [sandbox 000, control 404]
PASS  upstream refused when called directly, past the gateway  [sandbox 000, control 200]
PASS  claude -p finished its turn through the gateway  [2 turns: SPIKE_OK]
PASS  safety-net step completed and HEAD is the task branch  [(0, 'refs/heads/factory/spike-task')]
PASS  the worker's commit is on the task branch in the host's clone  [1 commit(s) by spike-worker[bot], 'spike: the worker commits', spike.txt: 'made by the worker']
PASS  the sandbox's Anthropic variables hold the run key and nothing else
INFO  sandbox {'read_only': False, 'cap_drop': ['ALL', 'NET_ADMIN'], 'cap_add': None, 'security_opt': ['no-new-privileges=true'], 'memory': 4294967296, 'nano_cpus': 2000000000, 'pids_limit': 512, 'published_on': []}
INFO  egress sidecar {'read_only': False, 'cap_drop': None, 'cap_add': ['NET_ADMIN'], 'security_opt': None, 'memory': 0, 'nano_cpus': 0, 'pids_limit': None, 'published_on': ['127.0.0.1']}
PASS  the model was called twice: a tool call, then text after its result
PASS  upstream saw the gateway's token and nothing from the sandbox (2 model calls)
```

How to read it:

- **The sandbox holds a run key, not a token.** The script makes a random key per run. The gateway accepts only that key and answers 401 without it. Its config holds the key's SHA-256 (`keyHash`), not the key. Anthropic has never heard of it.
- **A refusal has a control.** Each "refused" line is the same request made twice: from the sandbox (no HTTP answer, `000`) and from a plain container on the same Docker bridge (an HTTP answer). The difference between the two is the policy. The check does not look at why the sandbox's request failed.
- **The port check covers one port.** 15021 is open on the gateway and the rule names only 4000.
- **In mock mode a 401 can only come from the gateway,** because the mock never sends one. In real mode Anthropic could be its author.
- **The last line is the credential check.** For every model call (POST) the mock logged, the bearer must be the gateway's token and `x-api-key` must be absent, compared by hash. So the sandbox's key reached the upstream in neither header.
- **The work step has the factory's shape.** The script makes a repo and a clone of it, and mounts the clone at `/work` as `factory` does. OpenSandbox never runs an image's own entrypoint: its bootstrap starts the command API, then the `entrypoint` argument of `create()` (by default `tail -f /dev/null`). The factory's entrypoint cannot be named there as it is, because it reads its secret from stdin and expects a tmpfs, and OpenSandbox offers neither. So the driver runs the entrypoint's work steps as commands, which is also how OpenSandbox's own Claude Code example drives the agent: the task branch from `origin/main`, the agent, the safety-net commit (skipped when the agent failed, as under the entrypoint's `set -e`), and the check that HEAD is still the task branch. Here the agent commits its own work, so the safety net finds nothing to commit.
- **The model is canned.** The mock tells the worker to run one Bash command that writes a file and commits it, then answers `SPIKE_OK` once a tool result comes back. The check on the mock's replies requires exactly that pair, in that order.
- **The commit is read from the host's clone,** which is what the orchestrator would judge and push. The check does not run `git` on the host: the agent wrote that repo, and git executes what a repo's config names. It reads the clone from a throwaway container, mounted read-only with no network, as `factory`'s push step does. The commit must carry the identity passed in `GIT_AUTHOR_NAME` and must not be the safety net's. In mock mode it must be exactly the commit the tool call makes, which is the evidence that the tool ran.
- **The INFO lines are observations, not checks.** They are how the two containers were started.

## Real mode: a token Keycard and Anthropic issued

```bash
FACTORY_SECRETS_DIR=<dir> ./spike.sh real
```

Run twice, 2026-11-17, on the factory's Mac mini with Docker Desktop: first right after mock mode passed there, then again once the gateway's config held the run key's hash in place of the key. Both runs printed the lines below. The script got a token from Keycard for `https://api.anthropic.com`, traded it at Anthropic's federation endpoint as `factory` does, and wrote the result to the file the gateway mounts.

```
PASS  runs as the image's unprivileged user
PASS  gateway answers the run key
PASS  gateway refuses a model call with no key  [401]
PASS  gateway refuses a model call with a wrong key
PASS  npm registry reachable
PASS  api.anthropic.com refused (direct, by name)  [sandbox 000, control 404]
PASS  example.com refused  [sandbox 000, control 200]
PASS  unlisted IP refused (1.1.1.1)  [sandbox 000, control 301]
PASS  gateway refused on a port the rule does not name (15021)  [sandbox 000, control 404]
PASS  claude -p finished its turn through the gateway  [2 turns: SPIKE_OK]
PASS  safety-net step completed and HEAD is the task branch  [(0, 'refs/heads/factory/spike-task')]
PASS  the worker's commit is on the task branch in the host's clone  [1 commit(s) by spike-worker[bot], 'Add spike.txt', spike.txt: 'made by the worker']
PASS  the sandbox's Anthropic variables hold the run key and nothing else
```

What it adds to mock mode:

- **A real token went through the gateway.** The sandbox held only the run key, which is nothing to Anthropic, and Anthropic answered.
- **The model chose its own tool call.** The commit is `Add spike.txt`, not the mock's canned one. Claude Code's real requests passed through the gateway's parser with no extra setting.
- **The egress policy held on Docker Desktop.** Mock mode had only run on OrbStack.

What it does not show:

- **What Anthropic received, header by header.** The last two checks and the "past the gateway" check read the mock's log, so they run in mock mode only. Here the evidence is indirect.
- **A 401's author.** With no mock, Anthropic could have sent the 401 the two "refuses" checks look for. Mock mode is what shows the gateway sends it.
- **Exchange mode.** This was the token-file variant.

## Exchange mode: the gateway is given no token

```bash
./spike.sh exchange
```

Only this mock form has run. `./spike.sh exchange real` is written for the real zone and `api.anthropic.com` and has never run: the zone has none of the registrations listed below.

The sandbox holds a JWT that a stand-in Keycard issued for the worker, addressed to the gateway. The gateway starts with its own client secret and no model credential. It gets one by making two trades, in one agentgateway process and by configuration alone. Its token cache is turned off, so it trades again on every call:

1. The `default` listener checks the JWT (issuer, audience, signature) and trades it at Keycard's token endpoint for a token addressed to Anthropic. This is RFC 8693 token exchange with the gateway's client credentials.
2. It hands the call to an `inner` listener on loopback, which trades that token at Anthropic's federation endpoint for the API token. This is the RFC 7523 grant `factory` uses today.

**The two listeners are a workaround.** agentgateway v1.7.0 has one backend-auth slot per request and no documented way to chain two exchanges. Tried against this mock on 2026-11-17, with the two-listener config as the control:

- `backendAuth` under `llm.policies`: refused at startup (`unknown field backendAuth`).
- Two `backendAuth` policies at different levels of one explicit route: only the most specific ran, so the caller's JWT went to Anthropic's endpoint as the assertion and was rejected.
- `crossAppAccess`, the built-in two-step exchange: not run. In source it fixes the requested token type to ID-JAG and gives the second endpoint no `additionalParams`, so it cannot send the federation ids.
- `extAuthz` over HTTP making the Keycard trade, with the model's exchange reading `extauthz.token` as its subject token: works in one listener. It follows agentgateway's `traffic-token-exchange/extauthz` example, which builds the token request by hand in CEL. That is further from Keycard's guidance than the built-in policy, and it rules out `privateKeyJwt`.

The chain exists inside agentgateway (`ChainedExchange` in `http/auth/oauth/mod.rs`) but is not a config field and is limited to ID-JAG. Until it is exposed, the loopback hop keeps both trades on the built-in exchange client, with file-backed secrets.

The same checks pass as above, plus one that prints what agentgateway sent to each token endpoint:

```
PASS  both token endpoints accepted every request the gateway sent (count, then what it sent): 2 {"anthropic":{"client_auth":null,"params":["assertion","federation_rule_id","grant_type","organization_id","service_account_id","workspace_id"]}} 3 {"keycard":{"client_auth":"Basic","params":["grant_type","resource","subject_token","subject_token_type"]}}
```

The counts are per run: three calls reached the gateway (one listing models, two model calls), so Keycard's endpoint was asked three times and Anthropic's twice. With the cache on, each was asked once.

The mock endpoints accept only a POST with the exact subject token or assertion, grant, resource, client credentials and federation ids. The check passes when each endpoint accepted at least one request and refused none.

This variant was written with the `using-keycard` guide loaded. It departs from that guide in three places, listed under "Before this is real". Whether the real ones accept it is checked this far, with no credentials:

- **Keycard.** In a local copy of svc-sts (5213d2d2, 46 commits behind main on 2026-11-17; the checks named here were compared with main and had not changed), the token endpoint takes `client_secret_basic`. An access-token exchange needs a confidential client, a subject token the zone issued, and an exchanging application that provides the resource in the subject token's first `aud`. The subject token's `client_id` and `keycard_app_id` must resolve to a live application credential, and its `sub_profile` must be `app` or `user`. A token whose subject is an application is accepted, with no consent step. The same shape is in svc-sts's own integration tests, which call it the gateway pattern. No live exchange has been tried.
- **The mock's JWT has Keycard's shape, not its substance.** It carries `typ: at+jwt` and those three claims, and agentgateway's `jwtAuth` accepts it. The mock checks none of what Keycard would: it compares the token byte for byte. It also returns an opaque token where Keycard returns a signed JWT, so the mock Anthropic never sees the JWT the real federation endpoint needs.
- **Anthropic.** Its federation endpoint parsed a form body. With a garbage assertion it gave the same `401 Authentication failed` for JSON and for a form, and a form with no assertion gave `400 assertion is required`.

A real run needs these in the Keycard zone, none of which exist yet:

- A resource for the gateway whose credential provider is the zone itself, so its token is a JWT. The script expects the identifier `urn:factory:gateway:models` (`GATEWAY_RESOURCE` overrides it). Its token lifetime has to cover a whole worker step, because the worker presents the token on every model call; the default is 24 hours.
- An application for the gateway (say `urn:factory:gateway`) that provides that resource and has its own client ID and secret. Only the providing application may exchange a token addressed to the resource. The script reads the credential from `gateway_client_id` and `gateway_client_secret` in `FACTORY_SECRETS_DIR`.
- The orchestrator's application permitted on the gateway's resource. Under the default policy that means a dependency on it.
- The zone's `default-app-delegation` policy in the active set, or a permit for the gateway's application on `https://api.anthropic.com` when `context.on_behalf` is true.
- The orchestrator minting the worker's token with the gateway's resource in place of Anthropic's, and without the `openid` scope, which would add a second audience.
- The gateway's application depending on `https://api.anthropic.com`. Keycard's guide says to declare it. In source it is not what grants this exchange.

Policy then checks two legs. The gateway as actor is already permitted by the zone's default delegation policy. The orchestrator as subject needs the permission on `https://api.anthropic.com` it has today. So the orchestrator keeps its direct path to an Anthropic token: at Keycard, the gateway is one route to that token, not the only one.

Still open:

- Whether Anthropic's federation rule matches the exchanged token. Its subject would still be the orchestrator's application; `client_id` and `act` would name the gateway.
- Whether agentgateway's `jwtAuth` accepts a real Keycard access token as it is. The mock's token now has the real header type and claims. A real one comes from the zone's issuer, with keys at `<zone>/openidconnect/jwks`.
- One identity per agent. Today every step would present the orchestrator's identity. A separate Keycard application for the worker, the judge and the reviewer would let policy and the gateway's log tell them apart. In a run by hand, the gateway's request log carried `jwt.sub=urn:spike:worker`.

## Seen by hand, not in the script

- **Removing the gateway's `auth` block makes the last check fail.** The upstream then gets no credential at all.
- **A gateway with no key policy and no `auth` block forwards the caller's bearer upstream as `x-api-key`.** The mock received the caller's exact value. This is by design: agentgateway's Claude Code guide uses it for Claude Teams and Pro accounts. So a gateway that loses its config becomes a pass-through, not a wall.
- **The real route answers.** With a made-up token and no caller credential, Anthropic replied `401 Invalid bearer token` through the gateway. With no gateway token it replied `x-api-key header is required`. So the bearer Anthropic saw was the gateway's. No valid token has been tried.
- **Sidecar `v1.1.7` ignores ports.** That is the image `opensandbox-server init-config --example docker` writes into the config. It allowed every port on an allowed IP: its nftables rules match the address only. `release-1.2.1` enforces the port.
- **No read-only root.** I found no option for it in server 1.2.1's configuration source.

## Not run

- **A real exchange.** Exchange mode has only met mocks. `./spike.sh exchange real` reads the zone's discovery document, mints the worker's token for the gateway's resource and points the gateway at the real endpoints. What was checked without credentials: its gateway config loads, fetches the zone's keys and answers 401 to a missing or garbage token. The zone has none of the registrations it needs, so no trade has been tried.
- **A real task.** The worker makes one small commit in an empty repo, in one turn with one tool call. Nothing installs from npm, and no revision round continues an existing branch. agentgateway's docs mention `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` for one known error with beta headers; the real run did not need it. The entrypoint's exit codes (2 for a failed commit or a moved HEAD, 3 for no changes) and the stream of tool calls into `log.jsonl` are not reproduced. Nor are `run_container`'s watchdog, its redacting log pipeline, or the `NPM_CONFIG_BEFORE` npm policy.
- **A Linux host for the mount.** On a Mac, OrbStack and Docker Desktop let uid 1000 in the container write a clone owned by the host user. On Linux the ownership would have to match.
- **The other steps** (judge, push, review, verify), a Linux host, and the sidecar's decision log as a replacement for the proxy's record in `log.jsonl`.
- **A search of the sandbox for the token.** The script never passes a token in and the Dockerfile bakes none into the image. Nothing searches the container to confirm it; the check on its environment only guards the first half.

## Against the factory's `docker run`

| Factory today | Here |
|---|---|
| One secret over stdin, in the container for the whole step | A per-run gateway key; the token stays in the gateway |
| Per-step proxy, allowlist by host | Per-sandbox policy by host, or by IP and port, at the network layer |
| `--read-only` | Root filesystem is writable |
| `--cap-drop ALL` | Same, with `drop_capabilities = ["ALL"]` |
| `no-new-privileges`, 4 GB, 2 CPUs, 512 pids | Same on the sandbox; the sidecar has no limits |
| The image's entrypoint does the branch checkout, the safety-net commit and the exit codes | OpenSandbox never runs the image's entrypoint; the driver runs the checkout, the agent and the safety-net commit as commands, without the exit codes |
| `-v "$work":/work` | A host-path volume, allowed by `allowed_host_paths` in the server's config |
| The orchestrator is a bash script | A server with the Docker socket, and a sidecar with `NET_ADMIN`, join the trust boundary |

## Before this is real

- In token mode the run key is a shared random string and the token file is written once. Exchange mode replaces both, once the zone has the registrations above.
- **Token caching is off in exchange mode, on purpose.** agentgateway caches exchanged tokens in memory by default. Keycard's guidance is never to cache its tokens in the application, so the config sets `cache: {maxEntries: 0}`. The cost is two token requests per model call, and Anthropic's side of that is untested for rate limits.
- **Discovery happens once, in the script.** Keycard's guidance is to find the token endpoint and keys through discovery. agentgateway's exchange takes a fixed host and path, so in real mode `spike.sh` reads the zone's discovery document and writes what it says into the gateway's config. A long-lived gateway would not notice the endpoints change. `factory` itself still hard-codes `/oauth/2/token`.
- **Not Keycard's SDK.** The exchange is agentgateway's own RFC 8693 client, not `@keycardai/oauth`. That is the point of the spike, but it means Keycard's SDK behaviour (and its fixes) does not apply.
- **A client secret, not workload identity.** With no user present, Keycard's guidance prefers workload identity. agentgateway can authenticate with `privateKeyJwt`. Keycard accepts that for a public-key credential whose keys it can fetch from a `jwks_uri`, so the gateway's public key would have to be published where Keycard can reach it. That removes the shared secret. It is still not workload identity, which is a separate path in Keycard. The mock uses a client secret.
- **The orchestrator's own request departs too.** In real mode and in `factory` it uses a client secret and a hand-written request, not workload identity and Keycard's SDK.
- **TLS to a real token endpoint has to be named.** In agentgateway a `host` on port 443 does not turn TLS on. A real config writes `https://` in the host or sets `backendTLS`.
- **The gateway's stats and readiness ports listen on every interface** (15020 and 15021) unless `config.statsAddr` and `config.readinessAddr` say otherwise. The spike leaves 15021 open on purpose, as its control for the port rule.
- **Exact strings.** Keycard matches a resource identifier exactly, so `resources` in the gateway config has to equal the registered resource byte for byte.
- The API key policy also takes `allowedModels` and `budgets` per key, which would cover the model pin and a spend cap. Not tried. Budgets need `config.database` and a `metadata.name` on the key, or the gateway refuses to start.
- OpenSandbox publishes each sandbox's command API on a host port. `publish_host = "127.0.0.1"` keeps it on loopback; the default is every interface. Nothing authenticates that port in `direct` ingress mode, which the spike uses: per-sandbox access tokens need `gateway` mode. Loopback is the protection.
- **OpenSandbox has its own answer to the credential question, not used here.** Its Credential Vault injects credentials from the egress sidecar, by intercepting the sandbox's TLS. The spike gives that job to agentgateway on purpose. The two have not been compared.
- **Plain Docker is OpenSandbox's local-development runtime.** Its docs list runc for trusted workloads and local development, and point to gVisor, Kata or Firecracker for untrusted code. With a network policy that means Kata: the egress sidecar does not work under gVisor.
- Cleanup is best effort. A killed run can leave containers named `spike-<pid>-*` or `sandbox-*`.
