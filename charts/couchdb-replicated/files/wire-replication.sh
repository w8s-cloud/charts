#!/bin/sh
# Keeps this CouchDB pulling from every peer, and from nothing else.
#
# Runs beside CouchDB in the same pod and, every RECONCILE_SECONDS,
# derives what _replicator should hold from PEERS and makes it so: one
# document per peer, id `from-<peer>-<hash of its spec>`, so a changed
# spec (new password, new host, new tuning) is a new id and the old one
# is deleted rather than edited. Anything else named from-* is removed.
# Nothing is remembered between passes; a wiped database, a restarted
# pod or a hand-deleted document is back on the next pass.
#
# Pull only: each site pulls the others' changes into its own database.
# Every write reaches every site that way, and a site that cannot reach a
# peer only stops receiving; nothing is pushed at a site that is away.
#
# A pull whose peer went away crashes, and CouchDB retries it with a
# backoff that grows with each failure, so after a long outage it could
# sit idle for a long time after the peer is back. Each pass therefore
# asks the peer directly; if it answers while its pull is crashing, the
# document is rewritten, which restarts the pull at once. It resumes from
# its last checkpoint (checkpoints belong to the replication, not the
# document), so nothing is copied twice.
#
# With CONTINUOUS=false there are no documents: each pass runs one
# one-shot pull per peer through /_replicate and waits for it.
#
# Env: COUCHDB_USER COUCHDB_PASSWORD DATABASE CLUSTER_ID
#      PEERS ("<id>=<host> ...") CONTINUOUS CHECKPOINT_INTERVAL_MS
#      WORKER_PROCESSES WORKER_BATCH_SIZE CONNECTION_TIMEOUT_MS
#      RECONCILE_SECONDS
set -u

LOCAL=http://127.0.0.1:5984
AUTH="$COUCHDB_USER:$COUCHDB_PASSWORD"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

couch() { curl -sS -u "$AUTH" -H 'Content-Type: application/json' "$@"; }

# HTTP status of a request, body discarded.
status() { couch -o /dev/null -w '%{http_code}' "$@"; }

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# The replication document for pulling from one peer.
spec_for() {
  user=$(json_str "$COUCHDB_USER")
  pass=$(json_str "$COUCHDB_PASSWORD")
  basic="{\"basic\":{\"username\":\"$user\",\"password\":\"$pass\"}}"
  printf '{"source":{"url":"http://%s:5984/%s","auth":%s},' "$2" "$DATABASE" "$basic"
  printf '"target":{"url":"%s/%s","auth":%s},' "$LOCAL" "$DATABASE" "$basic"
  printf '"continuous":%s,"checkpoint_interval":%s,' "$CONTINUOUS" "$CHECKPOINT_INTERVAL_MS"
  printf '"worker_processes":%s,"worker_batch_size":%s,' "$WORKER_PROCESSES" "$WORKER_BATCH_SIZE"
  printf '"connection_timeout":%s,"w8s_peer":"%s","w8s_cluster":"%s"}' \
    "$CONNECTION_TIMEOUT_MS" "$1" "$CLUSTER_ID"
}

doc_id_for() {
  printf 'from-%s-%s' "$1" "$(printf '%s' "$2" | sha256sum | cut -c1-12)"
}

# "<id> <rev>" per replication document this script owns.
existing_docs() {
  couch "$LOCAL/_replicator/_all_docs?startkey=%22from-%22&endkey=%22from-%EF%BF%B0%22" \
    | grep -o '"id":"from-[^"]*","key":"[^"]*","value":{"rev":"[^"]*"' \
    | sed 's/^"id":"\([^"]*\)".*"rev":"\([^"]*\)"$/\1 \2/'
}

restart_if_peer_is_back() {
  couch "$LOCAL/_scheduler/docs/_replicator/$3" | grep -q '"state":"crashing"' || return 0
  couch -f -o /dev/null -m 5 "http://$2:5984/_up" 2>/dev/null || return 0
  rev=$(couch "$LOCAL/_replicator/$3" | grep -o '"_rev":"[^"]*"' | cut -d'"' -f4)
  status -X DELETE "$LOCAL/_replicator/$3?rev=$rev" >/dev/null
  code=$(status -X PUT "$LOCAL/_replicator/$3" -d "$4")
  log "$1 answers again; restarted its crashing pull $3 (HTTP $code)"
}

reconcile() {
  code=$(status -X PUT "$LOCAL/$DATABASE")
  case $code in
    201) log "created database $DATABASE" ;;
    412) ;;
    *) log "cannot create database $DATABASE: HTTP $code"; return 1 ;;
  esac

  want=""
  if [ "$CONTINUOUS" = true ]; then
    for entry in $PEERS; do
      peer=${entry%%=*}
      host=${entry#*=}
      spec=$(spec_for "$peer" "$host")
      id=$(doc_id_for "$peer" "$spec")
      want="$want $id"
      code=$(status -X PUT "$LOCAL/_replicator/$id" -d "$spec")
      case $code in
        201|202) log "pulling from $peer ($host) as $id" ;;
        409) restart_if_peer_is_back "$peer" "$host" "$id" "$spec" ;;
        *) log "cannot write $id: HTTP $code" ;;
      esac
    done
  fi

  existing_docs | while read -r id rev; do
    case " $want " in
      *" $id "*) ;;
      *)
        code=$(status -X DELETE "$LOCAL/_replicator/$id?rev=$rev")
        log "removed $id (HTTP $code)"
        ;;
    esac
  done

  if [ "$CONTINUOUS" != true ]; then
    for entry in $PEERS; do
      peer=${entry%%=*}
      spec=$(spec_for "$peer" "${entry#*=}")
      out=$(couch -m "$RECONCILE_SECONDS" -X POST "$LOCAL/_replicate" -d "$spec" 2>&1)
      log "one-shot pull from $peer: $(printf '%s' "$out" | cut -c1-200)"
    done
  fi
}

log "cluster $CLUSTER_ID, peers: ${PEERS:-none}, continuous: $CONTINUOUS"
while :; do
  if curl -sf -o /dev/null "$LOCAL/_up"; then
    reconcile || true
  else
    log "waiting for CouchDB"
  fi
  sleep "$RECONCILE_SECONDS"
done
