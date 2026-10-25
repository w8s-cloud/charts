#!/bin/sh
# nginx image entrypoint hook: renders this pod's server block from its
# template ($TEMPLATE) and environment. The key is substituted here so it
# never sits in a ConfigMap.
set -eu
case "$API_KEY" in
  *[!A-Za-z0-9_-]*) echo "the API key may hold only letters, digits, _ and -" >&2; exit 1 ;;
esac
upstream=${UPSTREAM:-}
sed -e "s#__KEY__#$API_KEY#g" \
    -e "s#__CLUSTER__#${CLUSTER_ID:-}#g" \
    -e "s#__GPU_CLUSTER__#${GPU_CLUSTER:-}#g" \
    -e "s#__MODEL__#${DEFAULT_MODEL:-}#g" \
    -e "s#__ENDPOINT__#${ENDPOINT:-}#g" \
    -e "s#__UPSTREAM_HOST__#${upstream%%:*}#g" \
    -e "s#__UPSTREAM__#$upstream#g" \
    "/etc/w8s/$TEMPLATE" > /etc/nginx/conf.d/default.conf
echo "rendered $TEMPLATE${upstream:+ -> $upstream}"
