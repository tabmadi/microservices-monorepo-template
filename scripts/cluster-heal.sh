#!/usr/bin/env bash
# Heal a local k3d cluster after a host reboot (ADR-0003).
#
# Docker's restart policy on the k3d node is `unless-stopped`, so on daemon start
# (after a reboot) Docker replays the node container RAW — without k3d's own start
# orchestration. That skips the step where k3d injects the `host.k3d.internal`
# alias + CoreDNS records, so on a proxied machine the node's proxy target becomes
# unresolvable: containerd can't pull the pause/CNI images, Cilium never comes up,
# and every pod hangs in ContainerCreating cluster-wide. `k3d cluster stop && start`
# is the fix — the start path re-injects the alias — so this wraps that as a
# one-liner. Idempotent and safe to run anytime the cluster looks wedged after a
# reboot. See docs/dev-loop.md ("After a reboot").
set -euo pipefail
CLUSTER="${CLUSTER:-platform}"

if ! k3d cluster list | awk '{print $1}' | grep -qx "$CLUSTER"; then
  echo "cluster '$CLUSTER' not found — nothing to heal (run 'mise run cluster:full')"
  exit 0
fi

CTX="k3d-${CLUSTER}"
k() { kubectl --context "$CTX" "$@"; }

echo "→ healing '$CLUSTER': stop + start to re-inject host.k3d.internal + CoreDNS records"
k3d cluster stop "$CLUSTER"
k3d cluster start "$CLUSTER"

# Confirm the alias is actually back — the whole point of the dance.
if docker exec "k3d-${CLUSTER}-server-0" grep -q host.k3d.internal /etc/hosts; then
  echo "✓ host.k3d.internal restored"
else
  echo "✗ host.k3d.internal still missing after restart — investigate k3d/CoreDNS" >&2
  exit 1
fi

# A k3d stop/start can leave Cilium's per-node datapath half-restored: pods then
# cannot egress to the node/API (10.43.0.1), which cascades to CoreDNS (its
# `kubernetes` plugin never goes ready) and every controller. A plain restart of
# the CNI + DNS rebuilds it. Do that, then PROVE recovery via CoreDNS readiness —
# CoreDNS is only Ready once a pod can actually reach the API, so it is the honest
# datapath probe. Fail loudly if it does not come back (no silent half-heal).
echo "→ rebuilding Cilium + CoreDNS datapath"
k -n kube-system rollout restart ds/cilium >/dev/null 2>&1 || true
k -n kube-system rollout status ds/cilium --timeout=180s || true
k -n kube-system rollout restart deploy/coredns >/dev/null 2>&1 || true

echo "→ verifying pod→API datapath (CoreDNS readiness)…"
if k -n kube-system rollout status deploy/coredns --timeout=180s; then
  # A reboot's raw node restart can change the docker-bridge gateway IP, so re-stamp
  # the host-only frontend edge glue (route + fresh host address) as part of healing.
  CLUSTER="$CLUSTER" bash scripts/cluster-edge-glue.sh
  echo "✓ heal complete: CoreDNS ready — pods can reach the API again"
else
  echo "✗ CoreDNS still not ready after heal — the Cilium pod-egress datapath is" >&2
  echo "  wedged deeper than a restart clears (pods cannot reach 10.43.0.1). This" >&2
  echo "  cluster's CNI state is corrupt; recreate it: mise run cluster:delete && \\" >&2
  echo "  CLUSTER_PRELOAD=1 mise run cluster:full" >&2
  exit 1
fi
