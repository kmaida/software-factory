# Spike: the worker step on OpenSandbox and agentgateway

Can the worker run with no Anthropic credential in its container? This spike runs Claude Code from the `factory-sandbox` image inside an [OpenSandbox](https://github.com/opensandbox-group/OpenSandbox) sandbox whose only route to a model is [agentgateway](https://agentgateway.dev), which holds the token and attaches it. Keycard stays the issuer. Nothing here is called by `factory`.

```bash
./spike.sh
```

That is mock mode: a stand-in for `api.anthropic.com` and a made-up token, so it costs nothing and needs no secret. With `FACTORY_SECRETS_DIR` set, the script mints the token the way `factory` does and uses the real API. It needs `docker`, `uv`, `jq`, `openssl` and the `factory-sandbox` image.

## What ran

Mock mode, 2026-11-16, on a Mac with OrbStack (Docker 29.8.2, arm64): opensandbox-server 1.2.1, egress sidecar v1.1.7, execd v1.1.0, agentgateway v1.7.0, Claude Code 2.1.316. Every check passed:

- The factory image runs unchanged, as uid 1000.
- Egress is default-deny, enforced by nftables in a sidecar. The gateway on port 4000 and `registry.npmjs.org` are reachable. `api.anthropic.com`, `example.com`, a bare IP, the gateway's admin port and the upstream itself are all refused.
- `claude -p` completes a turn with `ANTHROPIC_BASE_URL` set to the gateway and a placeholder for a token.
- The upstream received the gateway's token on every call and never the placeholder. With the gateway's `auth` block removed, this check fails: the upstream gets no bearer at all, because the gateway drops the caller's.

One probe outside the script: with a made-up token and no mock, Anthropic answered `401 Invalid bearer token` through the gateway. So the gateway reaches `/v1/messages` and presents the file's value as a bearer.

## Not run

- **Real mode.** The Keycard client secret is on the mini, so no real token has been through the gateway. Claude Code's real requests (beta headers, streaming, tool calls) through the gateway's parser are untested; its docs mention `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` for one known error.
- **A real task.** The sandbox gets an empty repo. Getting the clone in and the commits out (OpenSandbox volumes) is not tried.
- **The other steps** (judge, push, review, verify), a Linux host, and the egress sidecar's decision log as a replacement for the proxy's record in `log.jsonl`.

## Against the factory's `docker run`

| Factory today | Here |
|---|---|
| One secret over stdin, in the container for the whole step | No secret in the container |
| Per-step proxy, allowlist by host | Per-sandbox policy by host, IP and port, at the network layer |
| `--read-only` | Not available: server 1.2.1 has no read-only root option |
| `--cap-drop ALL` | Works with `drop_capabilities = ["ALL"]` |
| `no-new-privileges`, memory, CPU and pid limits | Same |
| The image's entrypoint does the branch checkout, the safety-net commit and the exit codes | OpenSandbox replaces the entrypoint; the orchestrator would run those as commands |
| The orchestrator is a bash script | A server with the Docker socket, and a sidecar with `NET_ADMIN`, join the trust boundary |

## Before this is real

- The gateway has no inbound auth, so anything on the Docker bridge can spend the token through it. It needs a per-run key or a Keycard-issued JWT (`jwtAuth`).
- The token file is written once. The schema says file values are watched, so a fresh token per round should need no restart; not tested.
- agentgateway's schema has an `oauthTokenExchange` backend auth with a `jwtBearer` grant, the same grant `factory` uses at Anthropic. The gateway could do that exchange itself from a Keycard token. Not tried: `factory` sends JSON to that endpoint and the gateway may send a form.
- OpenSandbox publishes each sandbox's command API on a host port. `publish_host = "127.0.0.1"` keeps it on loopback; the default is every interface.
