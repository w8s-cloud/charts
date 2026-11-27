#!/bin/sh
# Checks what can be checked without a cluster: the vendored upstream
# files are the pinned ones, crds/ holds their CRDs byte for byte, and the
# chart renders for each setting (and refuses the ones it should).
# Needs helm and sha256sum. Run from anywhere: sh test/check.sh
set -eu
chart=$(cd "$(dirname "$0")/.." && pwd)
cd "$chart"

sha256sum -c --quiet <<'SUMS'
9ac45a436c49d32e6fc21d542bcb7600b970705297b9e6752f3ef9b0a1d292da  files/kubevirt-v1.9.1/kubevirt-operator.yaml
c7d92bd1b2ee1a3952a5990000437c08d58109f31c0bd48ab6188ec27a13e224  files/cdi-v1.66.1/cdi-operator.yaml
5e25393b382931836b48a77a085c536b133d545dc2a1254702442ea4c0f2ed73  files/multus-v4.3.2/multus-daemonset-thick.yml
9781b39c24f3f651bd6d6e41b561e04e4904bbdb6d4f8c7a6009df3a702dcd65  files/local-path-v0.0.37/local-path-storage.yaml
SUMS

# The CustomResourceDefinition document of an upstream file, as it is.
crd() {
  awk 'function flush() { if (doc ~ /(^|\n)kind: CustomResourceDefinition\n/) printf "%s", doc; doc = "" }
       /^---[ \t]*$/ { flush(); next } { doc = doc $0 "\n" } END { flush() }' "$1"
}
crd files/kubevirt-v1.9.1/kubevirt-operator.yaml | cmp - crds/kubevirts.kubevirt.io.yaml
crd files/cdi-v1.66.1/cdi-operator.yaml | cmp - crds/cdis.cdi.kubevirt.io.yaml

helm lint . >/dev/null
helm lint . --set storage=local-path,multus.enabled=true,emulation=true >/dev/null

kinds() { helm template t . -n vm-platform "$@" | grep -c '^kind: '; }
[ "$(kinds)" = 18 ] || { echo "default: expected 18 objects, got $(kinds)" >&2; exit 1; }
[ "$(kinds --set storage=local-path)" = 27 ] || { echo "local-path: expected 27 objects" >&2; exit 1; }
[ "$(kinds --set multus.enabled=true)" = 24 ] || { echo "multus: expected 24 objects" >&2; exit 1; }

out=$(helm template t . -n vm-platform --set emulation=true,storage=local-path,multus.enabled=true)
echo "$out" | grep -q 'useEmulation: true'
echo "$out" | grep -q '"paths":\["/var/mnt/local-path-provisioner"\]'
echo "$out" | grep -q 'storageclass.kubernetes.io/is-default-class: "true"'
echo "$out" | grep -q 'multus-cni:v4.3.2-thick@sha256:'
! echo "$out" | grep -q 'snapshot-thick'

refuses() { if helm template t . "$@" >/dev/null 2>&1; then echo "should have failed: $*" >&2; exit 1; fi; }
refuses -n kubevirt
refuses -n cdi
refuses -n vm-platform --set storage=ceph
refuses -n vm-platform --set storage=local-path,localPath.path=relative

echo ok
