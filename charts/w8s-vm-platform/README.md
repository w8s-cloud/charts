# w8s-vm-platform

Reference platform: KubeVirt and CDI at pinned versions, so a cluster can
run the virtual machines that cannot move to containers yet. The *VMs on
Kubernetes* reference architecture.

Our position is software off VMs first: repackage the application as a
container and move its data once. This chart is the second choice, for
the long tail: bought software certified only for VMs, Windows-only
systems, systems close to their end. Give every VM it runs an exit date.

## Who installs it

**A cluster admin, with `helm install`.** It brings two operators, their
CRDs, cluster roles and a PriorityClass, which a w8s app install refuses
today (app installs may create only Deployments, StatefulSets, Services,
ConfigMaps, Secrets, PVCs, ServiceAccounts, NetworkPolicies, HTTPRoutes,
ServiceExports and Jobs). Installing it from w8s needs a permission for
platform charts that is not decided yet; until then:

```sh
helm install vm-platform oci://oci.w8s.cloud/charts/w8s-vm-platform \
  --version 0.1.0 -n vm-platform --create-namespace
```

Install it into a namespace of its own, never `kubevirt`, `cdi` or
`local-path-storage`: the chart creates those namespaces itself, and the
render fails if you pick one of them. The release's namespace stays empty.

## What it installs

| Part | Version | What | Where |
|---|---|---|---|
| KubeVirt operator | v1.9.1 | `virt-operator` and its CRD; it installs `virt-api`, `virt-controller`, `virt-handler` and every other KubeVirt CRD itself | namespace `kubevirt` |
| `KubeVirt` CR | | upstream's `kubevirt-cr.yaml`, plus `useEmulation` and `uninstallStrategy: BlockUninstallIfWorkloadsExist` | `kubevirt` |
| CDI operator | v1.66.1 (the CDI release made for KubeVirt 1.9) | `cdi-operator` and its CRD; it installs CDI's API server, controller, upload proxy and CRDs (`DataVolume`, ...) | namespace `cdi` |
| `CDI` CR | | upstream's `cdi-cr.yaml`, plus `uninstallStrategy: BlockUninstallIfWorkloadsExist` (CDI's own default removes DataVolumes) | cluster-scoped |
| Multus (thick plugin) | v4.3.2 | `multus.enabled`, off by default | DaemonSet in `kube-system` |
| local-path-provisioner | v0.0.37 | `storage: local-path`, lab only | namespace `local-path-storage` |

What the operators then create on their own (CRDs, webhooks, APIServices,
cluster roles, DaemonSets) they create as their own ServiceAccounts, with
the ClusterRoles this chart installs. That is upstream's design, not ours.

## Values

| Value | Default | |
|---|---|---|
| `emulation` | `false` | KubeVirt's `useEmulation`: run VMs in software where nodes have no `/dev/kvm` (nodes that are VMs without nested virtualisation). Slow; never on real servers. |
| `storage` | `none` | `none`: bring your own default StorageClass (Rook-Ceph, or a SAN's CSI driver); live migration needs RWX block volumes. `local-path`: local-path-provisioner as the default StorageClass, lab only. |
| `localPath.path` | `/var/mnt/local-path-provisioner` | the directory on each node |
| `localPath.defaultClass` | `true` | mark `local-path` as the default StorageClass |
| `multus.enabled` | `false` | Multus, for VMs bridged onto an existing VLAN |
| `multus.image` | `...multus-cni:v4.3.2-thick@sha256:109b88...` | the release's image by digest |

## Prerequisites the chart cannot do

- **KVM.** Nodes that run VMs need `/dev/kvm` (hardware virtualisation on
  in the firmware). Without it, `emulation: true`. A node can run VMs
  with KVM when it advertises `devices.kubevirt.io/kvm`.
- **Storage.** With `storage: none`, a default StorageClass before the
  first VM. CDI waits for one otherwise.
- **local-path on Talos.** Talos mounts nothing writable at the upstream
  default `/opt/local-path-provisioner`. Give every node a user volume
  named `local-path-provisioner` first; Talos mounts it at
  `/var/mnt/local-path-provisioner` and propagates it into the kubelet.
  That is a machine-config patch, which a chart cannot apply:

  ```yaml
  apiVersion: v1alpha1
  kind: UserVolumeConfig
  name: local-path-provisioner
  volumeType: directory
  ```

  `talosctl patch mc --patch @volume.yaml` on each node, then wait until
  `talosctl ls /var/mnt/local-path-provisioner` answers. `directory` puts
  it on the EPHEMERAL partition, so no second disk is needed
  (`ops/metal-lab/addons storage` in the w8s repository does exactly this).
- **Multus.** With Cilium, set `cni.exclusive=false` (Cilium's Helm
  value) first, or Cilium moves Multus's CNI config aside without an
  error. Each node needs a Linux bridge on the VLAN trunk (Talos machine
  config) and the `bridge` CNI plugin in `/opt/cni/bin`. On Talos, check
  that `/var/run` is a symlink to `/run` (`talosctl ls -l /var`); if not,
  the DaemonSet's `host-run-netns` path needs `/var/run/netns/`, which
  this chart does not set. Use `bridge` for VMs, not `macvlan` or
  `ipvlan`.

## Sources

Each file in `files/` is the upstream file as downloaded, checked against
the SHA-256 below (`test/check.sh` checks them). KubeVirt and CDI publish
no checksum file: their sums are GitHub's own digests of the release
assets, reproduced by a download, the same pins as `ops/metal-lab/addons`.

| File | Source | SHA-256 |
|---|---|---|
| `files/kubevirt-v1.9.1/kubevirt-operator.yaml` | https://github.com/kubevirt/kubevirt/releases/download/v1.9.1/kubevirt-operator.yaml | `9ac45a436c49d32e6fc21d542bcb7600b970705297b9e6752f3ef9b0a1d292da` |
| (the CR is written in `templates/kubevirt.yaml` from) `kubevirt-cr.yaml` | https://github.com/kubevirt/kubevirt/releases/download/v1.9.1/kubevirt-cr.yaml | `43106136dbce3312bdbfdeae612aacafc6c12da518d233f90645b4685d84a2af` |
| `files/cdi-v1.66.1/cdi-operator.yaml` | https://github.com/kubevirt/containerized-data-importer/releases/download/v1.66.1/cdi-operator.yaml | `c7d92bd1b2ee1a3952a5990000437c08d58109f31c0bd48ab6188ec27a13e224` |
| (the CR is written in `templates/cdi.yaml` from) `cdi-cr.yaml` | https://github.com/kubevirt/containerized-data-importer/releases/download/v1.66.1/cdi-cr.yaml | `a497f90de608c1df26f9ee4095289373f17132d74a2042ca03e00c17c964f8a7` |
| `files/multus-v4.3.2/multus-daemonset-thick.yml` | https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.3.2/deployments/multus-daemonset-thick.yml | `5e25393b382931836b48a77a085c536b133d545dc2a1254702442ea4c0f2ed73` |
| `files/local-path-v0.0.37/local-path-storage.yaml` | https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml | `9781b39c24f3f651bd6d6e41b561e04e4904bbdb6d4f8c7a6009df3a702dcd65` |

`crds/` holds the one CRD of each operator manifest, cut out byte for
byte (`test/check.sh` compares them). Helm must create a CRD before the
resource that uses it, which only `crds/` does; the templates render the
rest of each manifest and skip the CRD.

What the chart changes, and only there:

- **KubeVirt and CDI:** nothing in the operator manifests. The two CRs
  are upstream's plus the values above.
- **Multus:** the image. Upstream's manifest names the floating
  `snapshot-thick` tag even at the release tag; the chart pins the
  release's own `v4.3.2-thick` by digest. Its CRD gets
  `helm.sh/resource-policy: keep`.
- **local-path:** the three changes `ops/metal-lab/addons` makes: the node
  path, `pod-security.kubernetes.io/enforce: privileged` on its namespace
  (its helper pods mount host paths, which Talos's default `baseline`
  refuses) and the default-class annotation.

Images: the operator images are upstream's tags (`quay.io/kubevirt/virt-operator:v1.9.1`,
`quay.io/kubevirt/cdi-operator:v1.66.1`), as the release manifests ship
them; the operators pin their own component images. local-path's helper
pod uses upstream's untagged `docker.io/library/busybox`; left as
upstream ships it.

## Upgrades

Helm installs `crds/` once and never upgrades it. A chart version with a
new KubeVirt or CDI first needs its CRD applied by hand:

```sh
kubectl apply --server-side -f crds/
helm upgrade vm-platform ... -n vm-platform
```

The operator then updates its components and, by its
`workloadUpdateStrategy`, the running VMs.

## Uninstall

`helm uninstall` leaves the `KubeVirt` and `CDI` resources and every CRD
(`helm.sh/resource-policy: keep`, and Helm never deletes `crds/`), so an
uninstall can never take the VMs' disks with it. To remove the platform:

1. Delete every `VirtualMachine` and `DataVolume` you no longer want.
2. `kubectl -n kubevirt delete kubevirt kubevirt` and
   `kubectl delete cdi cdi`; both refuse while workloads remain. Wait
   until the operators have removed their components.
3. `helm uninstall vm-platform -n vm-platform`.
4. `kubectl delete crd kubevirts.kubevirt.io cdis.cdi.kubevirt.io`
   (and `network-attachment-definitions.k8s.cni.cncf.io` with Multus).

## Installing it from w8s: what a permission would need

The objects this chart renders, by scope. A w8s permission for platform
charts would have to allow creating, updating and deleting these:

- **Cluster-scoped:** `Namespace` (`kubevirt`, `cdi`; `local-path-storage`),
  `CustomResourceDefinition` (`kubevirts.kubevirt.io`,
  `cdis.cdi.kubevirt.io`; `network-attachment-definitions.k8s.cni.cncf.io`),
  `PriorityClass` (`kubevirt-cluster-critical`), `ClusterRole`,
  `ClusterRoleBinding`, `CDI`, and with local-path a `StorageClass`.
- **Namespaced, outside the release's namespace:** `ServiceAccount`,
  `Role`, `RoleBinding`, `Deployment`, `KubeVirt` (in `kubevirt` and
  `cdi`); `ConfigMap`, `Deployment` (in `local-path-storage`); a
  `DaemonSet`, `ConfigMap`, `ServiceAccount` (Multus, in `kube-system`).

Binding the operators' ClusterRoles (`kubevirt-operator` has `*` on
`kubevirt.io` and `cdi.kubevirt.io`, and rights over CRDs, webhooks,
APIServices, RBAC, DaemonSets and more) means the installer must hold
those rights itself or have `escalate` and `bind`: in practice the
identity that installs this chart is a cluster admin.

## Not tested

- **No install on a cluster yet.** `test/check.sh` (sums, the CRDs byte
  for byte, lint, renders for every setting, the refused values) passes;
  a `helm install` against a real or kind cluster has not been run.
- **Multus beside Cilium on Talos**, and a VM keeping its address across a
  live migration: the VM spike in `docs/vm-exit-reference-architecture.md`
  has to prove these.
- Upgrading from one chart version to the next (there is only one).
