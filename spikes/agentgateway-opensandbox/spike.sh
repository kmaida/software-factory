#!/usr/bin/env bash
# Spike: the factory's worker step on OpenSandbox, with agentgateway holding the Anthropic credential.
#   ./spike.sh                               mock mode: a stand-in upstream and a made-up token; no spend, no secret
#   FACTORY_SECRETS_DIR=<dir> ./spike.sh     real mode: the token the factory mints (Keycard, then Anthropic), api.anthropic.com
# Needs docker, uv, jq, openssl and the factory-sandbox image (docker build -t factory-sandbox ../..). One run at a time (port 8090).
# Not factory code: nothing here is called by `factory`, and nothing is hardened. See README.md for what it showed.
set -euo pipefail
umask 077
here=$(cd "$(dirname "$0")" && pwd)
export IMAGE=factory-sandbox:latest
AGW_IMAGE=cr.agentgateway.dev/agentgateway:v1.7.0
OSB_SERVER=opensandbox-server==1.2.1; OSB_SDK=opensandbox==1.2.1
OSB_PORT=8090   # 8080, the server's default, is OrbStack's on this Mac
eval "$(grep -E '^(FACTORY_MODEL|KEYCARD_ZONE|ANTHROPIC_[A-Z_]+)=' "$here/../../factory")"   # the factory's own constants, not a copy

d=$(mktemp -d "${TMPDIR:-/tmp}/spike.XXXXXX"); mkdir -p "$d/secrets" "$d/data"
agw="spike-$$-agw"; mock="spike-$$-mock"; server=   # named by pid: cleanup never touches another run's containers
cleanup() {   # best effort, and only what this run started
  [ -z "$server" ] || { kill "$server" 2>/dev/null; wait "$server" 2>/dev/null; } || true
  docker rm -f "$agw" "$mock" >/dev/null 2>&1 || true; rm -rf "$d"
}
trap cleanup EXIT
ip_of() { docker inspect -f '{{.NetworkSettings.Networks.bridge.IPAddress}}' "$1"; }

# The credential: only ever a file on the host, mounted into the gateway. The sandbox never gets it.
if [ -n "${FACTORY_SECRETS_DIR:-}" ]; then   # the factory's keycard_token and anthropic_token, inline. Not run yet: the secrets are on the mini.
  mode=real; upstream=
  kc=$(printf 'user = "%s:%s"\n' "$(cat "$FACTORY_SECRETS_DIR/keycard_client_id")" "$(cat "$FACTORY_SECRETS_DIR/keycard_client_secret")" \
    | curl -sS -m 30 -K - "$KEYCARD_ZONE/oauth/2/token" -d grant_type=client_credentials -d "resource=$ANTHROPIC_RESOURCE" | jq -r '.access_token // empty') || kc=
  [ -n "$kc" ] || { echo "spike: Keycard did not issue a token for $ANTHROPIC_RESOURCE (zone $KEYCARD_ZONE)" >&2; exit 1; }
  printf '%s' "$kc" | jq -Rsc --arg r "$ANTHROPIC_FEDERATION_RULE" --arg o "$ANTHROPIC_ORG" --arg s "$ANTHROPIC_SERVICE_ACCOUNT" --arg w "$ANTHROPIC_WORKSPACE" \
      '{grant_type:"urn:ietf:params:oauth:grant-type:jwt-bearer", assertion:., federation_rule_id:$r, organization_id:$o, service_account_id:$s, workspace_id:$w}' \
    | curl -sS -m 30 "$ANTHROPIC_RESOURCE/v1/oauth/token" -H "content-type: application/json" -d @- | jq -rj '.access_token // empty' > "$d/secrets/anthropic_token"; kc=
  [ -s "$d/secrets/anthropic_token" ] || { echo "spike: Anthropic did not exchange the Keycard token (rule $ANTHROPIC_FEDERATION_RULE)" >&2; exit 1; }
else
  mode=mock; printf 'made-up-%s' "$(openssl rand -hex 16)" > "$d/secrets/anthropic_token"
  docker run -d --name "$mock" -v "$here/mock-anthropic.js":/mock.js:ro --entrypoint node "$IMAGE" /mock.js >/dev/null
  MOCK_IP=$(ip_of "$mock"); export MOCK_IP
  upstream="params: {baseUrl: \"http://$MOCK_IP:9000/v1\"}"
fi
echo "spike: $mode mode"

# agentgateway: a caller with this run's key gets Anthropic with the file's token as the bearer; any other caller gets 401.
# The key is what the sandbox holds in place of the token. A gateway with neither this key policy nor the `auth` block
# passes the caller's bearer upstream as x-api-key (seen by hand, README.md), so the last check below looks at both headers.
# ponytail: a random key per run; a Keycard-issued JWT per agent (jwtAuth) when the gateway is more than a spike.
RUN_KEY=$(openssl rand -hex 24); export RUN_KEY
cat > "$d/agw.yaml" <<EOF
gateways:
  default:
    port: 4000
llm:
  policies:
    apiKey:
      mode: strict
      keys:
      - key: "$RUN_KEY"
  models:
  - name: "*"
    provider: anthropic
    $upstream
    auth:
      key:
        value: {file: /secrets/anthropic_token}
        location: {header: {name: authorization, prefix: "Bearer "}}
EOF
docker run -d --name "$agw" --user "$(id -u):$(id -g)" -v "$d/agw.yaml":/config.yaml:ro -v "$d/secrets":/secrets:ro -v "$d/data":/data \
  "$AGW_IMAGE" -f /config.yaml >/dev/null
up=; for _ in $(seq 20); do [[ $(docker logs "$agw" 2>&1) == *'started bind'* ]] && { up=1; break; }; sleep 0.5; done
[ -n "$up" ] || { docker logs "$agw" >&2; echo "spike: agentgateway did not start" >&2; exit 1; }
GW_IP=$(ip_of "$agw"); export GW_IP

# OpenSandbox: Docker runtime, egress enforced by nftables in a sidecar (DNS-only mode would let a bare IP through).
OSB_API_KEY=$(openssl rand -hex 16); export OSB_API_KEY OSB_DOMAIN="127.0.0.1:$OSB_PORT" FACTORY_MODEL
cat > "$d/sandbox.toml" <<EOF
[server]
host = "127.0.0.1"
port = $OSB_PORT
api_key = "$OSB_API_KEY"
[proxy]
resolve_internal = false
[runtime]
type = "docker"
execd_image = "opensandbox/execd:release-1.2.1"
[store]
type = "sqlite"
path = "$d/opensandbox.db"
[docker]
network_mode = "bridge"
publish_host = "127.0.0.1"
drop_capabilities = ["ALL"]
no_new_privileges = true
pids_limit = 512
[ingress]
mode = "direct"
[egress]
image = "opensandbox/egress:release-1.2.1"
mode = "dns+nft"
EOF
uvx "$OSB_SERVER" --config "$d/sandbox.toml" > "$d/server.log" 2>&1 & server=$!
up=; for _ in $(seq 60); do curl -fsS -m 2 -o /dev/null "http://$OSB_DOMAIN/health" 2>/dev/null && { up=1; break; }; sleep 1; done
[ -n "$up" ] || { tail -20 "$d/server.log" >&2; echo "spike: opensandbox-server did not start" >&2; exit 1; }

rc=0; uv run -q --with "$OSB_SDK" python "$here/drive.py" || rc=$?

if [ "$mode" = mock ]; then   # every model call the upstream received: the file's token as the bearer, and no x-api-key
  want="[\"$(shasum -a 256 < "$d/secrets/anthropic_token" | cut -c1-16)\",null]"
  calls=$(docker logs "$mock" 2>&1 | jq -R -c 'fromjson? | select(.method == "POST") | [.bearer_sha, .x_api_key_sha]')
  if [ "$(printf '%s\n' "$calls" | sort -u)" = "$want" ]; then echo "PASS  upstream saw the gateway's token and nothing from the sandbox ($(printf '%s\n' "$calls" | wc -l | tr -d ' ') model calls)"
  else echo "FAIL  upstream saw [bearer, x-api-key] hashes $(printf '%s\n' "$calls" | sort -u | tr '\n' ' '), wanted only $want"; rc=1; fi
fi
exit "$rc"
