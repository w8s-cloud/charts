#!/usr/bin/env bash
# The chart's own nginx files (the GPU gateway, the client endpoint, the
# render hook and the chat page) on one Docker host, in front of a stub
# that stands in for Ollama. The model registries are not needed, and no
# GPU: what is tested is everything this chart adds around Ollama.
#
# The "GPU pod" is two containers sharing one network namespace, as the
# pod's containers do: the stub on 127.0.0.1:11434 and the gateway on
# 8080. A Docker network stands in for the w8s tunnel: the gateway answers
# there under the name w8s would give its import. The client runs on that
# network with UPSTREAM pointing at that name. It checks:
#
#   1. the gateway refuses a request without the key, or with a wrong one
#   2. with the key, it forwards, and does not pass the key on to Ollama
#   3. the client adds the key: /api and /v1 work through it with none
#   4. tokens stream: the first arrives long before the answer finishes
#   5. the client serves the chat page and says which cluster answered
#   6. the render hook refuses a key it could not substitute safely
#
# Needs docker and curl. Leaves nothing running unless KEEP=1.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
files=$here/files
prefix=${PREFIX:-pi-test}
net=$prefix-tunnel
image=${NGINX_IMAGE:-nginx:1.27-alpine}
key=test-only-$(date +%s)
import=inference-gpu--ai--gpu-home.w8s-system.svc.cluster.local
gw_port=${GW_PORT:-18091}
client_port=${CLIENT_PORT:-18092}
work=$(mktemp -d)

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then echo "KEEP=1: leaving $prefix-* running"; return; fi
  docker rm -f $(docker ps -aq --filter "name=^$prefix-") >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
cleanup_quiet() { KEEP=0 cleanup; mkdir -p "$work"; }
cleanup_quiet

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

# The render hook is mounted executable, as the chart's ConfigMap volume
# (defaultMode 0755) mounts it.
cp "$files/40-render.sh" "$work/40-render.sh"
chmod 0755 "$work/40-render.sh"

# The stub: Ollama's model list, and an OpenAI-style streamed completion
# sent slowly after the headers and first token (limit_rate), so a
# buffering proxy would be caught holding it.
# It refuses any request that still carries an Authorization header: the
# gateway must strip the key.
cat > "$work/stub.conf" <<'EOF'
server {
  listen 127.0.0.1:11434;
  default_type application/json;
  if ($http_authorization) { return 400 '{"error":"the key reached ollama"}'; }
  location = /api/tags {
    return 200 '{"models":[{"name":"llama3.2:3b","size":2019393189}]}';
  }
  location = /v1/chat/completions {
    default_type text/event-stream;
    limit_rate_after 300;
    limit_rate 60;
    return 200 'data: {"choices":[{"delta":{"content":"Hello"}}]}

data: {"choices":[{"delta":{"content":" from"}}]}

data: {"choices":[{"delta":{"content":" the"}}]}

data: {"choices":[{"delta":{"content":" GPU"}}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]

';
  }
}
EOF

docker network create "$net" >/dev/null

echo "== GPU pod: stub Ollama + gateway, exported as $import"
docker run -d --name "$prefix-gpu" --network "$net" --network-alias "$import" \
  -p "127.0.0.1:$gw_port:8080" \
  -v "$work/stub.conf:/etc/nginx/conf.d/default.conf:ro" \
  "$image" >/dev/null
docker run -d --name "$prefix-gateway" --network "container:$prefix-gpu" \
  -e TEMPLATE=gateway.conf.template -e API_KEY="$key" \
  -v "$files/gateway.conf.template:/etc/w8s/gateway.conf.template:ro" \
  -v "$work/40-render.sh:/docker-entrypoint.d/40-render.sh:ro" \
  "$image" >/dev/null

echo "== client, in another cluster"
docker run -d --name "$prefix-client" --network "$net" \
  -p "127.0.0.1:$client_port:8080" \
  -e TEMPLATE=client.conf.template -e API_KEY="$key" \
  -e UPSTREAM="$import:8080" -e CLUSTER_ID=edge-a -e GPU_CLUSTER=gpu-home \
  -e DEFAULT_MODEL=llama3.2:3b -e ENDPOINT=http://inference.ai.svc \
  -v "$files/client.conf.template:/etc/w8s/client.conf.template:ro" \
  -v "$work/40-render.sh:/docker-entrypoint.d/40-render.sh:ro" \
  -v "$files/index.html:/usr/share/nginx/html/index.html:ro" \
  "$image" >/dev/null

gw=http://127.0.0.1:$gw_port
client=http://127.0.0.1:$client_port
for _ in $(seq 1 50); do
  if curl -fs "$gw/healthz" >/dev/null && curl -fs "$client/healthz" >/dev/null; then break; fi
  sleep 0.2
done
curl -fs "$gw/healthz" >/dev/null || { docker logs "$prefix-gateway" >&2; fail "gateway did not come up"; }
curl -fs "$client/healthz" >/dev/null || { docker logs "$prefix-client" >&2; fail "client did not come up"; }

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "== 1. the gateway needs the key"
[ "$(status "$gw/api/tags")" = 401 ] || fail "no key was let through"
[ "$(status -H 'Authorization: Bearer wrong' "$gw/api/tags")" = 401 ] || fail "a wrong key was let through"
[ "$(status -H "Authorization: Bearer ${key}x" "$gw/api/tags")" = 401 ] || fail "a longer key was let through"
pass "401 without a key, with a wrong one, and with the key plus a character"

echo "== 2. with the key it forwards, and strips it"
body=$(curl -fs -H "Authorization: Bearer $key" "$gw/api/tags") || fail "the key was refused"
grep -q '"llama3.2:3b"' <<<"$body" || fail "unexpected model list: $body"
pass "model list through the gateway; the stub saw no Authorization header"

echo "== 3. the client adds the key"
body=$(curl -fs "$client/api/tags") || fail "/api through the client failed"
grep -q '"llama3.2:3b"' <<<"$body" || fail "unexpected model list via the client: $body"
body=$(curl -fs -X POST -H 'Content-Type: application/json' \
  -d '{"model":"llama3.2:3b","stream":true,"messages":[{"role":"user","content":"hi"}]}' \
  "$client/v1/chat/completions") || fail "/v1 through the client failed"
grep -q '\[DONE\]' <<<"$body" || fail "the stream did not finish: $body"
[ "$(status "$client/other")" = 404 ] || fail "the client forwards more than /api and /v1"
pass "/api and /v1 answer through the client, which holds the key; other paths are 404"

echo "== 4. tokens stream through both proxies"
# The stub takes about five seconds to send the whole answer. Reading for
# two must already have given the first token, and not the end.
partial=$(curl -sN --max-time 2 -X POST -H 'Content-Type: application/json' \
  -d '{"stream":true}' "$client/v1/chat/completions" || true)
grep -q 'Hello' <<<"$partial" || fail "no token within two seconds: something buffers the stream"
! grep -q '\[DONE\]' <<<"$partial" || fail "the stub sent everything at once; the test proves nothing"
pass "first token within two seconds of a five-second answer"

echo "== 5. the chat page and the site"
curl -fs "$client/" | grep -q '<title>' || fail "no chat page at /"
site=$(curl -fs "$client/w8s/site")
grep -q '"cluster":"edge-a"' <<<"$site" && grep -q '"gpu_cluster":"gpu-home"' <<<"$site" \
  || fail "unexpected /w8s/site: $site"
curl -fsI "$client/api/tags" | grep -qi '^x-served-by-cluster: edge-a' || fail "no X-Served-By-Cluster header"
pass "chat page at /, /w8s/site names both clusters, responses say which cluster served them"

echo "== 6. the render hook refuses an unsafe key"
if docker run --rm -e TEMPLATE=client.conf.template -e 'API_KEY=a#b' -e UPSTREAM=x:80 \
  -v "$files/client.conf.template:/etc/w8s/client.conf.template:ro" \
  -v "$work/40-render.sh:/docker-entrypoint.d/40-render.sh:ro" \
  --entrypoint /docker-entrypoint.d/40-render.sh "$image" >/dev/null 2>&1; then
  fail "a key with # was accepted"
fi
pass "a key with characters outside [A-Za-z0-9_-] stops the container"

echo "all checks passed"
