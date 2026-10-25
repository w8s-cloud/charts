#!/usr/bin/env bash
# Three sites on one Docker host, running the chart's own files (the
# replication sidecar script, the guestbook's nginx config and page)
# against real CouchDB. A shared Docker network stands in for the w8s
# tunnels: each site's CouchDB answers there under the name w8s would give
# its import (couchdb--demo--<site>), and `docker network disconnect` is
# the partition. It checks what the chart promises:
#
#   1. a write at one site reaches the other two
#   2. every site runs one pull per peer
#   3. a partitioned site keeps taking writes, and the others keep
#      replicating with each other
#   4. after healing, the partitioned site catches up both ways, and a
#      document edited on both sides while apart shows the same winner and
#      the same conflict everywhere
#   5. resolving the conflict at one site clears it at all of them
#   6. a hand-deleted replication document comes back
#   7. removing a peer removes its pull
#
# Needs docker, curl and python3. Leaves nothing running unless KEEP=1.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
files=$here/files
prefix=${PREFIX:-cr-test}
net=$prefix-wan
user=admin
pass=test-only-$(date +%s)
sites=(a b c)
port_of() { case $1 in a) echo 18081 ;; b) echo 18082 ;; c) echo 18083 ;; esac; }
image_couch=${COUCH_IMAGE:-couchdb:3.4.2}
image_nginx=${NGINX_IMAGE:-nginx:1.27-alpine}
work=$(mktemp -d)

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then echo "KEEP=1: leaving $prefix-* running"; return; fi
  docker rm -f $(docker ps -aq --filter "name=^$prefix-") >/dev/null 2>&1 || true
  docker network rm "$net" "$prefix-site-a" "$prefix-site-b" "$prefix-site-c" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

log() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
api() { curl -sS "http://127.0.0.1:$(port_of "$1")$2" "${@:3}"; }
couch() { docker exec "$prefix-couch-$1" curl -sS -u "$user:$pass" "http://127.0.0.1:5984$2" "${@:3}"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# until <seconds> <description> <command...>
until_ok() {
  local limit=$1 what=$2; shift 2
  local start=$SECONDS
  while ! "$@" >/dev/null 2>&1; do
    [ $((SECONDS - start)) -ge "$limit" ] && fail "$what (after ${limit}s)"
    sleep 2
  done
  echo "ok: $what (${SECONDS}s total, $((SECONDS - start))s waiting)"
}

peers_of() {
  local me=$1 out=""
  for s in "${sites[@]}"; do
    [ "$s" = "$me" ] || out="$out $s=couchdb--demo--$s"
  done
  echo "${out# }"
}

start_sidecar() {
  local s=$1 peers=$2
  docker rm -f "$prefix-wire-$s" >/dev/null 2>&1 || true
  docker run -d --name "$prefix-wire-$s" --network "container:$prefix-couch-$s" \
    --user 5984 --entrypoint sh \
    -e COUCHDB_USER=$user -e COUCHDB_PASSWORD="$pass" -e CLUSTER_ID="$s" \
    -e DATABASE=guestbook -e PEERS="$peers" -e CONTINUOUS=true \
    -e CHECKPOINT_INTERVAL_MS=5000 -e WORKER_PROCESSES=1 -e WORKER_BATCH_SIZE=100 \
    -e CONNECTION_TIMEOUT_MS=10000 -e RECONCILE_SECONDS=5 \
    -v "$files/wire-replication.sh:/etc/w8s/wire-replication.sh:ro" \
    "$image_couch" /etc/w8s/wire-replication.sh >/dev/null
}

log "starting three sites"
docker network create "$net" >/dev/null
for s in "${sites[@]}"; do
  printf '[couchdb]\nsingle_node = true\nuuid = %s\n\n[chttpd]\nbind_address = any\n' \
    "$(printf '%s/demo/gb' "$s" | sha256sum | cut -c1-32)" > "$work/$s.ini"
  chmod 644 "$work/$s.ini"
  # As the chart's init container does: the settings file is copied in,
  # never mounted, because the image's entrypoint chowns /opt/couchdb.
  # Its own network carries the guestbook's published port; the shared
  # one is the "tunnel" the partition cuts.
  docker network create "$prefix-site-$s" >/dev/null
  docker create --name "$prefix-couch-$s" --network "$prefix-site-$s" \
    -p "127.0.0.1:$(port_of "$s"):8080" \
    -e COUCHDB_USER=$user -e COUCHDB_PASSWORD="$pass" \
    "$image_couch" >/dev/null
  docker cp "$work/$s.ini" "$prefix-couch-$s:/opt/couchdb/etc/local.d/10-w8s.ini"
  docker network connect --alias "couchdb--demo--$s" "$net" "$prefix-couch-$s"
  docker start "$prefix-couch-$s" >/dev/null
  docker run -d --name "$prefix-web-$s" --network "container:$prefix-couch-$s" \
    -e COUCHDB_USER=$user -e COUCHDB_PASSWORD="$pass" -e CLUSTER_ID="$s" \
    -e PEERS="${sites[*]/$s}" -e DATABASE=guestbook -e COUCHDB_ADDRESS=127.0.0.1:5984 \
    -v "$files/nginx.conf.template:/etc/w8s/nginx.conf.template:ro" \
    -v "$files/40-w8s-guestbook.sh:/docker-entrypoint.d/40-w8s-guestbook.sh:ro" \
    -v "$files/index.html:/usr/share/nginx/html/index.html:ro" \
    "$image_nginx" >/dev/null
done
for s in "${sites[@]}"; do
  until_ok 90 "site $s CouchDB up" couch "$s" /_up -f
  start_sidecar "$s" "$(peers_of "$s")"
done
for s in "${sites[@]}"; do
  until_ok 60 "site $s guestbook answers" sh -c "curl -sf http://127.0.0.1:$(port_of "$s")/api/site | grep -q '\"cluster\":\"$s\"'"
done

has_entry() { api "$1" /api/entries | grep -q "\"_id\":\"$2\""; }
entry() {
  local s=$1 id="entry:$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ):$1:$2"
  api "$s" /api/entries -X POST -H 'Content-Type: application/json' \
    -d "{\"_id\":\"$id\",\"name\":\"test\",\"message\":\"$2\",\"site\":\"$s\",\"at\":\"$(date -u +%FT%TZ)\"}" \
    | grep -q '"ok":true' || fail "writing $id at $s"
  echo "$id"
}

log "1-2. a write at one site reaches the others; every site pulls from both peers"
for s in "${sites[@]}"; do
  until_ok 60 "site $s runs 2 pulls" sh -c "[ \"\$(curl -sS http://127.0.0.1:$(port_of "$s")/api/replication | python3 -c \"import json,sys; print(sum(1 for x in json.load(sys.stdin).get('docs',[]) if x['state']=='running'))\")\" = 2 ]"
done
e1=$(entry a first)
for s in b c; do until_ok 60 "entry from a visible at $s" has_entry "$s" "$e1"; done

log "3. partition site a; it keeps taking writes, b and c keep replicating"
docker network disconnect "$net" "$prefix-couch-a"
e_a=$(entry a while-apart-at-a)
e_b=$(entry b while-apart-at-b)
api a /api/banner -X PUT -H 'Content-Type: application/json' \
  -d '{"text":"set at a while apart","site":"a","at":"t1"}' | grep -q '"ok":true' || fail "banner at a"
api b /api/banner -X PUT -H 'Content-Type: application/json' \
  -d '{"text":"set at b while apart","site":"b","at":"t2"}' | grep -q '"ok":true' || fail "banner at b"
until_ok 60 "entry written at b during the partition reaches c" has_entry c "$e_b"
sleep 10
has_entry b "$e_a" && fail "a's write crossed a partition"
has_entry a "$e_b" && fail "b's write crossed a partition"
echo "ok: nothing crossed the partition in 10s"

log "4. heal; a catches up both ways; the banner conflict is the same everywhere"
docker network connect --alias couchdb--demo--a "$net" "$prefix-couch-a"
heal=$SECONDS
until_ok 600 "a's write during the partition reaches b" has_entry b "$e_a"
until_ok 600 "a's write during the partition reaches c" has_entry c "$e_a"
until_ok 600 "b's write during the partition reaches a" has_entry a "$e_b"
echo "caught up $((SECONDS - heal))s after healing"
banner_state() { api "$1" '/api/banner?conflicts=true' | json "d['_rev']+' '+d['text']+' conflicts='+str(len(d.get('_conflicts',[])))"; }
same_banner_everywhere() {
  local a b c
  a=$(banner_state a); b=$(banner_state b); c=$(banner_state c)
  [ "$a" = "$b" ] && [ "$b" = "$c" ] && [[ "$a" == *"conflicts=1" ]]
}
until_ok 300 "the same winner and one conflict at all three sites" same_banner_everywhere
banner_state a

log "5. resolving at c clears the conflict everywhere"
winner=$(api c '/api/banner?conflicts=true')
win_rev=$(echo "$winner" | json "d['_rev']")
lose_rev=$(echo "$winner" | json "d['_conflicts'][0]")
lose_text=$(api c "/api/banner?rev=$lose_rev" | json "d['text']")
api c /api/banner -X PUT -H 'Content-Type: application/json' \
  -d "{\"_rev\":\"$win_rev\",\"text\":\"$lose_text\",\"site\":\"c\",\"at\":\"t3\"}" | grep -q '"ok":true' || fail "keep at c"
api c "/api/banner?rev=$lose_rev" -X DELETE | grep -q '"ok":true' || fail "delete losing revision at c"
resolved_everywhere() {
  for s in "${sites[@]}"; do
    [ "$(banner_state "$s" | cut -d' ' -f2-)" = "$lose_text conflicts=0" ] || return 1
  done
}
until_ok 120 "banner reads \"$lose_text\" with no conflicts at all three sites" resolved_everywhere

log "6. a hand-deleted replication document comes back"
doc=$(couch b '/_replicator/_all_docs' | grep -o '"id":"from-a-[^"]*","key":"[^"]*","value":{"rev":"[^"]*"' | head -1)
id=$(echo "$doc" | sed 's/^"id":"\([^"]*\)".*/\1/')
rev=$(echo "$doc" | sed 's/.*"rev":"\([^"]*\)"$/\1/')
couch b "/_replicator/$id?rev=$rev" -X DELETE | grep -q '"ok":true' || fail "deleting $id at b"
until_ok 30 "$id recreated at b" sh -c "docker exec $prefix-couch-b curl -sf -u '$user:$pass' http://127.0.0.1:5984/_replicator/$id"

log "7. removing a peer removes its pull"
start_sidecar c "a=couchdb--demo--a"
until_ok 30 "c no longer pulls from b" sh -c "! docker exec $prefix-couch-c curl -sS -u '$user:$pass' http://127.0.0.1:5984/_replicator/_all_docs | grep -q '\"id\":\"from-b-'"
until_ok 30 "c still pulls from a" sh -c "docker exec $prefix-couch-c curl -sS -u '$user:$pass' http://127.0.0.1:5984/_replicator/_all_docs | grep -q '\"id\":\"from-a-'"

log "all checks passed"
