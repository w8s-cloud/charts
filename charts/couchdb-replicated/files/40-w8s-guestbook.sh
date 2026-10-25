#!/bin/sh
# nginx image entrypoint hook: renders the guestbook's server block from
# the template and the pod's environment. The Authorization value is
# computed here so the password never sits in a ConfigMap.
set -eu
auth=$(printf '%s:%s' "$COUCHDB_USER" "$COUCHDB_PASSWORD" | base64 | tr -d '\n')
sed -e "s#__AUTH__#$auth#g" \
    -e "s#__CLUSTER__#$CLUSTER_ID#g" \
    -e "s#__PEERS__#$PEERS#g" \
    -e "s#__DB__#$DATABASE#g" \
    -e "s#__COUCH__#$COUCHDB_ADDRESS#g" \
    /etc/w8s/nginx.conf.template > /etc/nginx/conf.d/default.conf
echo "guestbook for cluster $CLUSTER_ID -> $COUCHDB_ADDRESS/$DATABASE"
