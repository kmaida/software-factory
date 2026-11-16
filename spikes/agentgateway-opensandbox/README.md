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
PASS  gateway's other ports refused (15021 readiness)  [sandbox 000, control 404]
PASS  upstream refused when called directly, past the gateway  [sandbox 000, control 200]
PASS  claude -p completed a turn through the gateway  [SPIKE_OK]
PASS  the sandbox's Anthropic variables hold the run key and nothing else
INFO  sandbox {'read_only': False, 'cap_drop': ['NET_ADMIN', 'ALL'], 'cap_add': None, 'security_opt': ['no-new-privileges=true'], 'memory': 4294967296, 'nano_cpus': 2000000000, 'pids_limit': 512, 'published_on': []}
INFO  egress sidecar {'read_only': False, 'cap_drop': None, 'cap_add': ['NET_ADMIN'], 'security_opt': None, 'memory': 0, 'nano_cpus': 0, 'pids_limit': None, 'published_on': ['127.0.0.1']}
PASS  upstream saw the gateway's token and nothing from the sandbox (1 model calls)
```

How to read it:

- **The sandbox holds a run key, not a token.** The script makes a random key per run. The gateway accepts only that key and answers 401 without it. Anthropic has never heard of it.
- **A refusal has a control.** Each "refused" line is the same request made twice: from the sandbox (no connection, `000`) and from a plain container on the same Docker bridge (an HTTP answer). So the policy is what refused it, not the network.
- **The last line is the credential check.** For every model call the mock received, it compares hashes of both `Authorization` and `x-api-key` with the gateway's token. The sandbox's key must appear in neither.
- **The INFO lines are observations, not checks.** They are how the two containers were started.

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
- **A search of the sandbox for the token.** That no token is in the container holds because the script never passes one in. The check on its environment only guards that.

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

- The run key is a shared random string. A Keycard-issued JWT per agent (`jwtAuth`) would tie each call to an identity.
- The token file is written once. The schema says file values are watched, so a fresh token per round should need no restart; not tested.
- agentgateway's schema has an `oauthTokenExchange` backend auth with a `jwtBearer` grant, the same grant `factory` uses at Anthropic. The gateway could do that exchange itself from a Keycard token. Not tried: `factory` sends JSON to that endpoint and the gateway may send a form.
- The API key policy also takes `allowedModels` and `budgets` per key, which would cover the model pin and a spend cap. Not tried.
- OpenSandbox publishes each sandbox's command API on a host port. `publish_host = "127.0.0.1"` keeps it on loopback; the default is every interface.
- Cleanup is best effort. A killed run can leave containers named `spike-<pid>-*` or `sandbox-*`.
