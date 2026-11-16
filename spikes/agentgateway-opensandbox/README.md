# Spike: the worker step on OpenSandbox and agentgateway

Can the worker run with no Anthropic credential in its container? This spike runs Claude Code from the `factory-sandbox` image inside an [OpenSandbox](https://github.com/opensandbox-group/OpenSandbox) sandbox whose only route to a model is [agentgateway](https://agentgateway.dev), which holds the token and attaches it. Keycard stays the issuer. Nothing here is called by `factory`.

```bash
./spike.sh
```

That is mock mode: a stand-in for `api.anthropic.com` and a made-up token, so it costs nothing and needs no secret. With `FACTORY_SECRETS_DIR` set, the script mints the token the way `factory` does and uses the real API. It needs `docker`, `uv`, `jq`, `openssl` and the `factory-sandbox` image.

## What the script checks

Mock mode, last run 2026-11-16 on a Mac with OrbStack (Docker 29.8.2, arm64). The pins are in `spike.sh`: opensandbox-server 1.2.1, egress sidecar and execd `release-1.2.1`, agentgateway v1.7.0. The image carries Claude Code 2.1.316.

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
PASS  claude -p completed a turn through the gateway  [SPIKE_OK]
PASS  the sandbox's Anthropic variables hold the run key and nothing else
INFO  sandbox {'read_only': False, 'cap_drop': ['ALL', 'NET_ADMIN'], 'cap_add': None, 'security_opt': ['no-new-privileges=true'], 'memory': 4294967296, 'nano_cpus': 2000000000, 'pids_limit': 512, 'published_on': []}
INFO  egress sidecar {'read_only': False, 'cap_drop': None, 'cap_add': ['NET_ADMIN'], 'security_opt': None, 'memory': 0, 'nano_cpus': 0, 'pids_limit': None, 'published_on': ['127.0.0.1']}
PASS  upstream saw the gateway's token and nothing from the sandbox (1 model calls)
```

How to read it:

- **The sandbox holds a run key, not a token.** The script makes a random key per run. The gateway accepts only that key and answers 401 without it. Anthropic has never heard of it.
- **A refusal has a control.** Each "refused" line is the same request made twice: from the sandbox (no HTTP answer, `000`) and from a plain container on the same Docker bridge (an HTTP answer). The difference between the two is the policy. The check does not look at why the sandbox's request failed.
- **The port check covers one port.** 15021 is open on the gateway and the rule names only 4000.
- **In mock mode a 401 can only come from the gateway,** because the mock never sends one. In real mode Anthropic could be its author.
- **The last line is the credential check.** For every model call (POST) the mock logged, the bearer must be the gateway's token and `x-api-key` must be absent, compared by hash. So the sandbox's key reached the upstream in neither header.
- **The INFO lines are observations, not checks.** They are how the two containers were started.

## Exchange mode: the gateway is given no token

```bash
./spike.sh exchange
```

Mock only. The sandbox holds a JWT that a stand-in Keycard issued for the worker, addressed to the gateway. The gateway starts with its own client secret and no model credential. It gets one by making two trades, in one agentgateway process and by configuration alone. Its token cache is turned off, so it trades again on every call:

1. The `default` listener checks the JWT (issuer, audience, signature) and trades it at Keycard's token endpoint for a token addressed to Anthropic. This is RFC 8693 token exchange with the gateway's client credentials.
2. It hands the call to an `inner` listener on loopback, which trades that token at Anthropic's federation endpoint for the API token. This is the RFC 7523 grant `factory` uses today.

The same checks pass as above, plus one that prints what agentgateway sent to each token endpoint:

```
PASS  both token endpoints accepted every request the gateway sent (count, then what it sent): 1 {"anthropic":{"client_auth":null,"params":["assertion","federation_rule_id","grant_type","organization_id","service_account_id","workspace_id"]}} 2 {"keycard":{"client_auth":"Basic","params":["grant_type","resource","subject_token","subject_token_type"]}}
```

The counts are per run: two calls reached the gateway (one listing models, one model call), so Keycard's endpoint was asked twice. With the cache on it was asked once.

The mock endpoints accept only a POST with the exact subject token or assertion, grant, resource, client credentials and federation ids. The check passes when each endpoint accepted at least one request and refused none.

This variant was written with the `using-keycard` guide loaded. It departs from that guide in three places, listed under "Before this is real". Whether the real ones accept it is checked this far, with no credentials:

- **Keycard.** In a local copy of svc-sts (5213d2d2, which may be behind), the token endpoint takes `client_secret_basic`, and an access-token exchange needs a confidential client, a subject token the zone issued, and an exchanging application that provides the resource in the subject token's first `aud`. A token whose subject is an application is accepted. No live exchange has been tried.
- **Anthropic.** Its federation endpoint parsed a form body. With a garbage assertion it gave the same `401 Authentication failed` for JSON and for a form, and a form with no assertion gave `400 assertion is required`.

A real run needs these in the Keycard zone, none of which exist yet:

- A resource for the gateway, and an application for the gateway that provides it and has its own credential.
- That application depending on `https://api.anthropic.com`, with policy that permits the exchange.
- The orchestrator minting the worker's token with the gateway's resource in place of Anthropic's.

Still open:

- Whether Anthropic's federation rule matches the exchanged token. Its subject would still be the orchestrator's application; `client_id` and `act` would name the gateway.
- Whether agentgateway's `jwtAuth` accepts a real Keycard access token as it is.
- One identity per agent. Today every step would present the orchestrator's identity. A separate Keycard application for the worker, the judge and the reviewer would let policy and the gateway's log tell them apart. In a run by hand, the gateway's request log carried `jwt.sub=urn:spike:worker`.

## Seen by hand, not in the script

- **Removing the gateway's `auth` block makes the last check fail.** The upstream then gets no credential at all.
- **A gateway with no key policy and no `auth` block forwards the caller's bearer upstream as `x-api-key`.** The mock received the caller's exact value. So a gateway that loses its config becomes a pass-through, not a wall.
- **The real route answers.** With a made-up token and no caller credential, Anthropic replied `401 Invalid bearer token` through the gateway. With no gateway token it replied `x-api-key header is required`. So the bearer Anthropic saw was the gateway's. No valid token has been tried.
- **Sidecar `v1.1.7` ignores ports.** That is the image `opensandbox-server init-config --example docker` writes into the config. It allowed every port on an allowed IP: its nftables rules match the address only. `release-1.2.1` enforces the port.
- **No read-only root.** I found no option for it in server 1.2.1's configuration source.

## Not run

- **Real mode.** The Keycard client secret is on the mini, so no real token has been through the gateway. Claude Code's real requests (beta headers, tool calls) through the gateway's parser are untested; its docs mention `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` for one known error.
- **A real task.** The sandbox runs one trivial prompt in an empty directory. Getting a clone in and commits out (OpenSandbox volumes) is not tried.
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
| The image's entrypoint does the branch checkout, the safety-net commit and the exit codes | OpenSandbox replaces the entrypoint; the orchestrator would run those as commands |
| The orchestrator is a bash script | A server with the Docker socket, and a sidecar with `NET_ADMIN`, join the trust boundary |

## Before this is real

- In token mode the run key is a shared random string and the token file is written once. Exchange mode replaces both, once the zone has the registrations above.
- **Token caching is off in exchange mode, on purpose.** agentgateway caches exchanged tokens in memory by default. Keycard's guidance is never to cache its tokens in the application, so the config sets `cache: {maxEntries: 0}`. The cost is two token requests per model call, and Anthropic's side of that is untested for rate limits.
- **No discovery.** Keycard's guidance is to find the token endpoint and keys through discovery. agentgateway's exchange takes a fixed host and path, so a real config would hard-code what the zone's discovery document says today. Real mode in `spike.sh` also hard-codes `/oauth/2/token`, as `factory` does.
- **Not Keycard's SDK.** The exchange is agentgateway's own RFC 8693 client, not `@keycardai/oauth`. That is the point of the spike, but it means Keycard's SDK behaviour (and its fixes) does not apply.
- **A client secret, not workload identity.** With no user present, Keycard's guidance prefers workload identity. agentgateway can authenticate with `privateKeyJwt`, which Keycard accepts; the mock uses a client secret.
- **Exact strings.** Keycard matches a resource identifier exactly, so `resources` in the gateway config has to equal the registered resource byte for byte.
- The API key policy also takes `allowedModels` and `budgets` per key, which would cover the model pin and a spend cap. Not tried.
- OpenSandbox publishes each sandbox's command API on a host port. `publish_host = "127.0.0.1"` keeps it on loopback; the default is every interface.
- Cleanup is best effort. A killed run can leave containers named `spike-<pid>-*` or `sandbox-*`.
