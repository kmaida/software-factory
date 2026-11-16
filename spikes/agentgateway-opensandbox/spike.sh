#!/usr/bin/env bash
# Spike: the factory's worker step on OpenSandbox, with agentgateway holding the Anthropic credential.
#   ./spike.sh                               mock mode: a stand-in upstream and a made-up token; no spend, no secret
#   FACTORY_SECRETS_DIR=<dir> ./spike.sh     real mode: the token the factory mints (Keycard, then Anthropic), api.anthropic.com
# Needs docker, uv, jq, openssl and the factory-sandbox image (docker build -t factory-sandbox ../..). Removes what it starts.
# Not factory code: nothing here is called by `factory`, and nothing is hardened. See README.md for what it showed.
set -euo pipefail
umask 077
here=$(cd "$(dirname "$0")" && pwd)
IMAGE=${IMAGE:-factory-sandbox:latest}
AGW_IMAGE=cr.agentgateway.dev/agentgateway:v1.7.0
OSB_SERVER=opensandbox-server==1.2.1; OSB_SDK=opensandbox==1.2.1
OSB_PORT=${OSB_PORT:-8090}   # 8080, the server's default, is OrbStack's on this Mac
eval "$(grep -E '^(FACTORY_MODEL|KEYCARD_ZONE|ANTHROPIC_[A-Z_]+)=' "$here/../../factory")"   # the factory's own constants, not a copy

d=$(mktemp -d "${TMPDIR:-/tmp}/spike.XXXXXX"); mkdir -p "$d/secrets" "$d/data"
server=
cleanup() { [ -z "$server" ] || kill "$server" 2>/dev/null || true; docker rm -f spike-agw spike-mock >/dev/null 2>&1 || true; rm -rf "$d"; }
trap cleanup EXIT
ip_of() { docker inspect -f '{{.NetworkSettings.Networks.bridge.IPAddress}}' "$1"; }
sha() { shasum -a 256 | cut -c1-16; }

# The credential: only ever a file on the host, mounted into the gateway. The sandbox never gets it.
if [ -n "${FACTORY_SECRETS_DIR:-}" ]; then   # the factory's keycard_token and anthropic_token, inline. Not run yet: the secrets are on the mini.
  mode=real; upstream=
  printf 'user = "%s:%s"\n' "$(cat "$FACTORY_SECRETS_DIR/keycard_client_id")" "$(cat "$FACTORY_SECRETS_DIR/keycard_client_secret")" \
  | curl -sS -m 30 -K - "$KEYCARD_ZONE/oauth/2/token" -d grant_type=client_credentials -d "resource=$ANTHROPIC_RESOURCE" | jq -r '.access_token // empty' \
  | jq -Rsc --arg r "$ANTHROPIC_FEDERATION_RULE" --arg o "$ANTHROPIC_ORG" --arg s "$ANTHROPIC_SERVICE_ACCOUNT" --arg w "$ANTHROPIC_WORKSPACE" \
      '{grant_type:"urn:ietf:params:oauth:grant-type:jwt-bearer", assertion:(.|rtrimstr("\n")), federation_rule_id:$r, organization_id:$o, service_account_id:$s, workspace_id:$w}' \
  | curl -sS -m 30 "$ANTHROPIC_RESOURCE/v1/oauth/token" -H "content-type: application/json" -d @- | jq -rj '.access_token // empty' > "$d/secrets/anthropic_token"
  [ -s "$d/secrets/anthropic_token" ] || { echo "spike: no Anthropic token (Keycard $KEYCARD_ZONE, rule $ANTHROPIC_FEDERATION_RULE)" >&2; exit 1; }
else
  mode=mock; printf 'made-up-%s' "$(openssl rand -hex 16)" > "$d/secrets/anthropic_token"
  docker run -d --name spike-mock -v "$here/mock-anthropic.js":/mock.js:ro --entrypoint node "$IMAGE" /mock.js >/dev/null
  MOCK_IP=$(ip_of spike-mock); export MOCK_IP
  upstream="params: {baseUrl: \"http://$MOCK_IP:9000/v1\"}"
fi
echo "spike: $mode mode"

# agentgateway: every model name goes to Anthropic with the file's token as the bearer, whatever the caller sent.
# ponytail: no inbound auth; anything on the bridge can spend the token through it. A per-run key or a Keycard JWT (jwtAuth) before this is real.
cat > "$d/agw.yaml" <<EOF
gateways:
  default:
    port: 4000
llm:
  models:
  - name: "*"
    provider: anthropic
    $upstream
    auth:
      key:
        value: {file: /secrets/anthropic_token}
        location: {header: {name: authorization, prefix: "Bearer "}}
EOF
docker run -d --name spike-agw --user "$(id -u):$(id -g)" -v "$d/agw.yaml":/config.yaml:ro -v "$d/secrets":/secrets:ro -v "$d/data":/data \
  "$AGW_IMAGE" -f /config.yaml >/dev/null
for _ in $(seq 20); do docker logs spike-agw 2>&1 | grep -q 'started bind' && break; sleep 0.5; done
docker logs spike-agw 2>&1 | grep -q 'started bind' || { docker logs spike-agw >&2; echo "spike: agentgateway did not start" >&2; exit 1; }
GW_IP=$(ip_of spike-agw); export GW_IP

# OpenSandbox: Docker runtime, egress enforced by nftables in a sidecar (DNS-only mode would let a bare IP through).
OSB_API_KEY=$(openssl rand -hex 16); export OSB_API_KEY OSB_DOMAIN="127.0.0.1:$OSB_PORT" IMAGE FACTORY_MODEL
cat > "$d/sandbox.toml" <<EOF
[server]
host = "127.0.0.1"
port = $OSB_PORT
api_key = "$OSB_API_KEY"
[proxy]
resolve_internal = false
[runtime]
type = "docker"
execd_image = "opensandbox/execd:v1.1.0"
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
image = "opensandbox/egress:v1.1.7"
mode = "dns+nft"
EOF
uvx "$OSB_SERVER" --config "$d/sandbox.toml" > "$d/server.log" 2>&1 & server=$!
for _ in $(seq 60); do curl -fsS -m 2 -o /dev/null "http://$OSB_DOMAIN/health" 2>/dev/null && break; sleep 1; done
curl -fsS -m 2 -o /dev/null "http://$OSB_DOMAIN/health" || { tail -20 "$d/server.log" >&2; echo "spike: opensandbox-server did not start" >&2; exit 1; }

rc=0; uv run -q --with "$OSB_SDK" python "$here/drive.py" || rc=$?

if [ "$mode" = mock ]; then   # what the upstream received: the file's token on every call, never the sandbox's placeholder
  want=$(sha < "$d/secrets/anthropic_token"); seen=$(docker logs spike-mock 2>&1 | jq -r 'select(.method) | .bearer_sha' | sort -u)
  if [ "$seen" = "$want" ]; then echo "PASS  upstream saw only the gateway's token ($(docker logs spike-mock 2>&1 | grep -c '"method"') calls)"
  else echo "FAIL  upstream saw bearer hashes [$seen], wanted $want"; rc=1; fi
fi
exit "$rc"
