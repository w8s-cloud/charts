# w8s-vm-migration (not built: a design note)

Meant to be: Forklift (kubev2v/forklift, upstream of Red Hat's Migration
Toolkit for Virtualization) at a pinned version, installed with plain
`helm install` like `w8s-vm-platform`, so a cluster running KubeVirt can
move VMs from vSphere. It is the chart behind the *Move VMs from vSphere*
reference architecture.

**There is no chart here yet, on purpose.** Forklift has no clean, pinned
way to install without OLM (the Operator Lifecycle Manager) today, and
assembling one from its development files would be a hack we would have
to own. This note says what is missing, so the decision can be made
rather than discovered. Checked on 2026-11-27 against the tags `v2.12.11`
(2026-11-25) and `v5.0.0`.

## What upstream offers

- **The documented install is OLM.** `operator/forklift-k8s.yaml` is a
  Namespace, a `CatalogSource` on `quay.io/kubev2v/forklift-operator-index:latest`,
  an `OperatorGroup` and a `Subscription` to the `development` channel.
  It needs OLM on the cluster (another operator with its own CRDs), and
  it follows a moving index: nothing in it is pinned.
- **No release carries manifests.** The newest GitHub release, v2.12.1
  (2026-06-30), ships only `kubectl-mtv` binaries. Later versions are git
  tags without releases.
- **The kustomize source is a development artefact.**
  `operator/config/default` (CRDs, RBAC, the manager Deployment) and its
  rendered copy `operator/.kustomized_manifests` exist, but every image is
  a `${...}` placeholder (eighteen images: operator, controller, API,
  validation, virt-v2v, populators, OVA server, ...), and the rendered
  copy also holds OLM's `ClusterServiceVersion`.
- **The images are not pinnable from upstream.** `quay.io/kubev2v/*` has
  only branch tags (`release-2.12`, `release-5.0`, `latest`), rebuilt
  continuously; the last versioned tag is `release-v2.6.5` (2024). The
  digests the tag `v2.12.11` names in `operator/export-vars-upstream.sh`
  (Konflux builds, rewritten to `quay.io/kubev2v`) are not in
  `quay.io/kubev2v` (the registry answers 404 for the operator and
  controller digests; the lookup returns 200 for the current
  `release-2.12` digest, so the method is right). Two of them are
  all-zero placeholders.
- **On Kubernetes it needs cert-manager.** The operator (Ansible-based)
  notices there is no `route.openshift.io` and then issues its webhook and
  service certificates through cert-manager `Certificate`s; on OpenShift
  the service CA does it. cert-manager is one more cluster-scoped operator.

## What a clean chart would need

1. **Images by digest that stay pullable**: either upstream publishes
   versioned images (or a release with a manifest), or we mirror a dated
   digest of each `release-2.12` image into our own registry and pin that.
   The second makes w8s the publisher of record for eighteen Red Hat
   built images: a decision, not a detail.
2. **The non-OLM manifests**: `operator/config/default` rendered with
   `kustomize build` at a tag, the `${...}` filled with the digests from
   step 1, the `ClusterServiceVersion` left out, vendored like the KubeVirt
   manifests in `w8s-vm-platform` and checked by SHA-256 in the README.
3. **cert-manager** as a stated prerequisite (or a dependency).
4. **A `ForkliftController` CR** with the OpenShift-only features off
   (UI plugin, CLI download, MCP server), and the VMware **VDDK image**
   left to the customer: VMware's licence does not let us ship it, and
   warm migration needs it.

Alternatives to weigh: install OLM and pin the `CatalogSource` image by
digest (two operators instead of one, still upstream's path); or keep
Forklift outside w8s (our ops scripts or the customer's GitOps) and have
w8s only check it is there.

## The migration inventory

The *Move VMs from vSphere* entry will also carry the migration inventory:
an RVTools export imported, and per VM a path (move the software, bring
the VM, retire, keep), a wave and its state. That is not built either,
and is not part of this chart (`docs/vm-exit-plan.md`, W3, in the w8s
repository).
