#!/usr/bin/env bash
# Spike: the factory's worker step on OpenSandbox, with agentgateway holding the Anthropic credential.
#   ./spike.sh              mock mode: a stand-in upstream and a made-up token; no spend, no secret
#   ./spike.sh real         real mode: the token the factory mints (Keycard, then Anthropic), api.anthropic.com. Spends.
#                           Needs FACTORY_SECRETS_DIR, and is never chosen by that variable alone: the mini exports it.
#   ./spike.sh exchange     mock mode, and the gateway is given no token: it trades the sandbox's Keycard-issued
#                           JWT at Keycard's token endpoint, then that result at Anthropic's, on the way out
#   ./spike.sh exchange real   the same against the real zone and api.anthropic.com. Spends. Also needs gateway_client_id and
#                           gateway_client_secret in FACTORY_SECRETS_DIR, and the zone registrations in README.md
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
for v in FACTORY_MODEL KEYCARD_ZONE ANTHROPIC_RESOURCE ANTHROPIC_FEDERATION_RULE ANTHROPIC_ORG ANTHROPIC_SERVICE_ACCOUNT ANTHROPIC_WORKSPACE; do
  [ -n "${!v:-}" ] || { echo "spike: factory no longer defines $v; this script reads it by that name" >&2; exit 2; }; done
variant=token; mode=mock
for a in "$@"; do case "$a" in token|exchange) variant=$a ;; real) mode=real ;; *) echo "usage: spike.sh [token|exchange] [real]" >&2; exit 2 ;; esac; done
if [ "$mode" = real ]; then
  [ -n "${FACTORY_SECRETS_DIR:-}" ] || { echo "spike: real mode needs FACTORY_SECRETS_DIR" >&2; exit 2; }
  need="keycard_client_id keycard_client_secret"; [ "$variant" = token ] || need="$need gateway_client_id gateway_client_secret"
  for s in $need; do [ -s "$FACTORY_SECRETS_DIR/$s" ] || { echo "spike: missing or empty $FACTORY_SECRETS_DIR/$s" >&2; exit 2; }; done
fi
GATEWAY_RESOURCE=${GATEWAY_RESOURCE:-urn:factory:gateway:models}   # exchange real: the zone resource the worker's token is addressed to

d=$(mktemp -d "${TMPDIR:-/tmp}/spike.XXXXXX"); d=$(cd "$d" && pwd -P); mkdir -p "$d/secrets" "$d/data"   # the real path: OpenSandbox compares mounts with it
agw="spike-$$-agw"; mock="spike-$$-mock"; server=   # named by pid: cleanup never touches another run's containers
cleanup() {   # best effort, and only what this run started
  [ -z "$server" ] || { kill "$server" 2>/dev/null; wait "$server" 2>/dev/null; } || true
  docker rm -f "$agw" "$mock" >/dev/null 2>&1 || true; rm -rf "$d"
}
trap cleanup EXIT
ip_of() { docker inspect -f '{{.NetworkSettings.Networks.bridge.IPAddress}}' "$1"; }
# Every log this script prints goes through here: a token endpoint's error can echo the request, and a gateway's
# start-up log its config. A secret is matched by its name as well as by its shape, and before any line is cut short.
redact() {
  perl -pe '
    s/eyJ[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]*)*/[jwt]/g;
    s/sk-ant-[A-Za-z0-9_-]+/[token]/g;
    s/\b(Bearer|Basic)\s+[^\s",]+/$1 [redacted]/gi;
    s/((?:client_secret|client_assertion|subject_token|actor_token|access_token|refresh_token|id_token|assertion|password|secret|api[_-]?key|authorization|token)["\x27]?\s*[:=]\s*["\x27]?)(?!\[)[^\s",&}\x27]+/$1\[redacted]/gi;
    s/\bcode=[^\s",&}]+/code=[redacted]/gi;
    s/[A-Za-z0-9_+\/=-]{40,}/[opaque]/g;
  '
}
[ "$(printf '%s' 'client_secret=abc "access_token":"q9" authorization: bearer zz code=c1 key AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA eyJa.b.c' | redact)" = \
  'client_secret=[redacted] "access_token":"[redacted]" authorization: [redacted] [redacted] code=[redacted] key [opaque] [jwt]' ] || { echo "spike: redact does not redact; is perl missing?" >&2; exit 2; }

# The credential: only ever a file on the host, mounted into the gateway. The sandbox never gets it.
if [ "$mode" = real ]; then   # the factory's keycard_token and anthropic_token, inline. Ran on the mini 2026-11-17 (README.md).
  upstream=
  # Keycard's rule: find the endpoints by discovery, never assume them. Done here, once; the gateway's config is then static.
  disc=$(curl -fsS -m 15 "$KEYCARD_ZONE/.well-known/oauth-authorization-server") || { echo "spike: no discovery document at $KEYCARD_ZONE" >&2; exit 1; }
  KC_ISS=$(jq -r '.issuer // empty' <<<"$disc"); KC_TOKEN_URL=$(jq -r '.token_endpoint // empty' <<<"$disc"); KC_JWKS=$(jq -r '.jwks_uri // empty' <<<"$disc")
  [[ -n "$KC_ISS" && "$KC_TOKEN_URL" == https://*/* && "$KC_JWKS" == https://* ]] || { echo "spike: discovery at $KEYCARD_ZONE named no https issuer, token endpoint and keys" >&2; exit 1; }
  kc_token() {   # kc_token <resource>: the orchestrator's own token for one resource, as the factory's keycard_token gets it
    printf 'user = "%s:%s"\n' "$(cat "$FACTORY_SECRETS_DIR/keycard_client_id")" "$(cat "$FACTORY_SECRETS_DIR/keycard_client_secret")" \
      | curl -sS -m 30 -K - "$KC_TOKEN_URL" -d grant_type=client_credentials --data-urlencode "resource=$1" | jq -r '.access_token // empty'
  }
  if [ "$variant" = token ]; then
    kc=$(kc_token "$ANTHROPIC_RESOURCE") || kc=
    [ -n "$kc" ] || { echo "spike: Keycard did not issue a token for $ANTHROPIC_RESOURCE (zone $KEYCARD_ZONE)" >&2; exit 1; }
    printf '%s' "$kc" | jq -Rsc --arg r "$ANTHROPIC_FEDERATION_RULE" --arg o "$ANTHROPIC_ORG" --arg s "$ANTHROPIC_SERVICE_ACCOUNT" --arg w "$ANTHROPIC_WORKSPACE" \
        '{grant_type:"urn:ietf:params:oauth:grant-type:jwt-bearer", assertion:., federation_rule_id:$r, organization_id:$o, service_account_id:$s, workspace_id:$w}' \
      | curl -sS -m 30 "$ANTHROPIC_RESOURCE/v1/oauth/token" -H "content-type: application/json" -d @- | jq -rj '.access_token // empty' > "$d/secrets/anthropic_token"; kc=
    [ -s "$d/secrets/anthropic_token" ] || { echo "spike: Anthropic did not exchange the Keycard token (rule $ANTHROPIC_FEDERATION_RULE)" >&2; exit 1; }
  fi
else
  printf 'made-up-%s' "$(openssl rand -hex 16)" > "$d/secrets/anthropic_token"
  GW_SECRET=$(openssl rand -hex 16); printf '%s' "$GW_SECRET" > "$d/secrets/gateway_client_secret"   # the gateway's own client secret at the mock Keycard
  FED=$(jq -nc --arg r "$ANTHROPIC_FEDERATION_RULE" --arg o "$ANTHROPIC_ORG" --arg s "$ANTHROPIC_SERVICE_ACCOUNT" --arg w "$ANTHROPIC_WORKSPACE" \
    '{federation_rule_id:$r, organization_id:$o, service_account_id:$s, workspace_id:$w}')   # what the mock Anthropic must be sent; ids, not secrets
  docker run -d --name "$mock" -e GW_SECRET="$GW_SECRET" -e FED="$FED" -v "$here/mock-anthropic.js":/mock.js:ro --entrypoint node "$IMAGE" /mock.js >/dev/null
  up=; for _ in $(seq 20); do [[ $(docker logs "$mock" 2>&1) == *'"listening"'* ]] && { up=1; break; }; sleep 0.5; done
  [ -n "$up" ] || { docker logs "$mock" 2>&1 | redact >&2; echo "spike: the mock did not start" >&2; exit 1; }
  MOCK_IP=$(ip_of "$mock"); export MOCK_IP
  upstream="params: {baseUrl: \"http://$MOCK_IP:9000/v1\"}"
fi
echo "spike: $mode mode, $variant"

# agentgateway: a caller with this run's key gets Anthropic with the file's token as the bearer; any other caller gets 401.
# The key is what the sandbox holds in place of the token. A gateway with neither this key policy nor the `auth` block
# passes the caller's bearer upstream as x-api-key (seen by hand, README.md), so the last check below looks at both headers.
# ponytail: a random key per run; a Keycard-issued JWT per agent (jwtAuth) when the gateway is more than a spike.
if [ "$variant" = token ]; then
RUN_KEY=$(openssl rand -hex 24)
cat > "$d/agw.yaml" <<EOF
gateways:
  default:
    port: 4000
llm:
  policies:
    apiKey:
      mode: strict
      keys:
      - keyHash: "sha256:$(printf '%s' "$RUN_KEY" | shasum -a 256 | cut -d' ' -f1)"   # the config never holds the key itself
  models:
  - name: "*"
    provider: anthropic
    $upstream
    auth:
      key:
        value: {file: /secrets/anthropic_token}
        location: {header: {name: authorization, prefix: "Bearer "}}
EOF
else
# exchange: the sandbox holds a JWT Keycard issued for the worker, addressed to the gateway. It is no use anywhere else, and at
# Keycard only the gateway's application may trade it. Two hops, because Anthropic takes a Keycard token only at its own
# federation endpoint: `default` checks the JWT and trades it at Keycard (RFC 8693) for a token addressed to Anthropic, then
# hands the call to `inner` on loopback, which trades that at Anthropic (RFC 7523, the grant `factory` uses) for the API token.
# The gateway holds its own client secret and no model credential. README.md has what the real zone needs.
if [ "$mode" = mock ]; then
  RUN_KEY=$(docker logs "$mock" 2>&1 | jq -R -r 'fromjson? | .agent_jwt // empty'); rm -f "$d/secrets/anthropic_token"
  KC_ISS=http://mock-keycard; KC_JWKS="http://$MOCK_IP:9000/jwks"; GW_AUD=urn:spike:gateway
  KC_HOST="$MOCK_IP:9000"; KC_PATH=/oauth/2/token; GW_CLIENT=spike-gateway; AN_HOST="$MOCK_IP:9000"
else   # the orchestrator mints the worker's token, addressed to the gateway's resource: of no use at Anthropic, or to any other client at Keycard
  RUN_KEY=$(kc_token "$GATEWAY_RESOURCE") || RUN_KEY=
  [ -n "$RUN_KEY" ] || { echo "spike: Keycard did not issue the worker a token for $GATEWAY_RESOURCE (zone $KEYCARD_ZONE): is the orchestrator permitted on it?" >&2; exit 1; }
  jq -Rr 'split(".")[1] | gsub("-"; "+") | gsub("_"; "/") | @base64d | fromjson | "INFO  worker token: sub=\(.sub) aud=\(.aud) lifetime=\(.exp - .iat)s"' <<<"$RUN_KEY" 2>/dev/null || true
  printf '%s' "$(cat "$FACTORY_SECRETS_DIR/gateway_client_secret")" > "$d/secrets/gateway_client_secret"   # no trailing newline; the gateway reads the file as it is
  GW_AUD=$GATEWAY_RESOURCE; GW_CLIENT=$(cat "$FACTORY_SECRETS_DIR/gateway_client_id")
  KC_HOST=$(cut -d/ -f1-3 <<<"$KC_TOKEN_URL"); KC_PATH=/$(cut -d/ -f4- <<<"$KC_TOKEN_URL"); AN_HOST=$ANTHROPIC_RESOURCE   # an https:// host is what turns TLS on
fi
cat > "$d/agw.yaml" <<EOF
gateways:
  default:
    port: 4000
  inner:
    port: 4001
    bindAddress: 127.0.0.1
routes:
- gateways: default
  policies:
    jwtAuth:
      mode: strict
      issuer: "$KC_ISS"
      audiences: ["$GW_AUD"]
      jwks: {url: "$KC_JWKS"}
      preserveToken: true
  backends:
  - host: 127.0.0.1:4001
    policies:
      backendAuth:
        oauthTokenExchange:
          host: "$KC_HOST"
          path: "$KC_PATH"
          resources: ["$ANTHROPIC_RESOURCE"]
          clientAuth: {method: clientSecretBasic, clientId: "$GW_CLIENT", clientSecret: {file: /secrets/gateway_client_secret}}
          cache: {maxEntries: 0}   # Keycard's rule: never cache its tokens in the application; trade again on every call
llm:
  gateways: inner
  models:
  - name: "*"
    provider: anthropic
    $upstream
    auth:
      oauthTokenExchange:
        host: "$AN_HOST"
        path: /v1/oauth/token
        grantType: jwtBearer
        cache: {maxEntries: 0}
        additionalParams:
          federation_rule_id: "'$ANTHROPIC_FEDERATION_RULE'"
          organization_id: "'$ANTHROPIC_ORG'"
          service_account_id: "'$ANTHROPIC_SERVICE_ACCOUNT'"
          workspace_id: "'$ANTHROPIC_WORKSPACE'"
EOF
fi
[ -n "$RUN_KEY" ] || { echo "spike: nothing for the sandbox to present to the gateway" >&2; exit 1; }; export RUN_KEY
docker run -d --name "$agw" --user "$(id -u):$(id -g)" -v "$d/agw.yaml":/config.yaml:ro -v "$d/secrets":/secrets:ro -v "$d/data":/data \
  "$AGW_IMAGE" -f /config.yaml >/dev/null
up=; for _ in $(seq 20); do [[ $(docker logs "$agw" 2>&1) == *'started bind'* ]] && { up=1; break; }; sleep 0.5; done
[ -n "$up" ] || { docker logs "$agw" 2>&1 | redact >&2; echo "spike: agentgateway did not start" >&2; exit 1; }
GW_IP=$(ip_of "$agw"); export GW_IP

# The repo, as `factory` hands it to the worker: a clone whose origin/main is the base, mounted at /work.
g() { git -c commit.gpgsign=false -c user.name=spike -c user.email=spike@example.invalid "$@"; }
g init -q -b main "$d/origin"; g -C "$d/origin" commit -q --allow-empty -m base; g clone -q "$d/origin" "$d/work"; export WORK_DIR="$d/work"

# OpenSandbox: Docker runtime, egress enforced by nftables in a sidecar (DNS-only mode would let a bare IP through).
OSB_API_KEY=$(openssl rand -hex 16); export OSB_API_KEY OSB_DOMAIN="127.0.0.1:$OSB_PORT" FACTORY_MODEL
cat > "$d/sandbox.toml" <<EOF
[server]
host = "127.0.0.1"
port = $OSB_PORT
api_key = "$OSB_API_KEY"
[runtime]
type = "docker"
execd_image = "opensandbox/execd:release-1.2.1"
[storage]
allowed_host_paths = ["$d/work"]
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
[ -n "$up" ] || { tail -20 "$d/server.log" | redact >&2; echo "spike: opensandbox-server did not start" >&2; exit 1; }

rc=0; uv run -q --with "$OSB_SDK" python "$here/drive.py" || rc=$?
# A failed real exchange is explained in the gateway's log (the token endpoint's own error), which the run would otherwise delete.
[ "$rc" = 0 ] || [ "$mode$variant" != realexchange ] || docker logs "$agw" 2>&1 | grep -i -E 'error|denied|invalid' | tail -6 | redact | cut -c1-500 >&2 || true

if [ "$mode" = mock ]; then   # every model call the upstream received: the file's token as the bearer, and no x-api-key
  seen=$(docker logs "$mock" 2>&1)
  if [ "$variant" = token ]; then tok=$(shasum -a 256 < "$d/secrets/anthropic_token" | cut -c1-16)
  else   # the token the mock Anthropic issued; and each token endpoint took every request the gateway sent it
    tok=$(jq -R -r 'fromjson? | .anthropic_token_sha // empty' <<<"$seen")
    ex=$(jq -R -c 'fromjson? | select(.token_endpoint) | [.token_endpoint, .ok]' <<<"$seen" | sort -u | tr '\n' ' ')
    if [ "$ex" = '["anthropic",true] ["keycard",true] ' ]; then echo "PASS  both token endpoints accepted every request the gateway sent (count, then what it sent): $(jq -R -c 'fromjson? | select(.token_endpoint) | {(.token_endpoint): {client_auth, params}}' <<<"$seen" | sort | uniq -c | sed -E 's/^ +//' | tr '\n' ' ')"
    else echo "FAIL  token endpoints saw [endpoint, accepted]: ${ex:-nothing}"; rc=1; fi
  fi
  replies=$(jq -R -r 'fromjson? | select(.method == "POST") | .reply' <<<"$seen" | tr '\n' ' ')   # the worker's turn: one tool call, then the answer to its result
  if [ "$replies" = 'tool_use text ' ]; then echo "PASS  the model was called twice: a tool call, then text after its result"
  else echo "FAIL  the mock model's replies were [${replies% }], wanted [tool_use text]"; rc=1; fi
  want="[\"$tok\",null]"
  calls=$(jq -R -c 'fromjson? | select(.method == "POST") | [.bearer_sha, .x_api_key_sha]' <<<"$seen")
  if [ "$(printf '%s\n' "$calls" | sort -u)" = "$want" ]; then echo "PASS  upstream saw the gateway's token and nothing from the sandbox ($(printf '%s\n' "$calls" | wc -l | tr -d ' ') model calls)"
  else echo "FAIL  upstream saw [bearer, x-api-key] hashes $(printf '%s\n' "$calls" | sort -u | tr '\n' ' '), wanted only $want"; rc=1; fi
fi
exit "$rc"
