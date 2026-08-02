#!/usr/bin/env bash
# Ensure the single local k3d cluster exists and is running (ADR-0003, ADR-0016).
# Convergent: create it if absent, start it if stopped (cluster:stop keeps the
# image cache + volumes; cluster:delete deletes it). One cluster serves both local
# tiers; what differs is what you bring up on it:
#   mise run cluster:lite     → inner loop (lightweight deps, run services natively)
#   mise run cluster:full   → full platform via ArgoCD
#
# Flannel + the built-in network policy are disabled because Cilium is the CNI
# (NetworkPolicy + Hubble, ADR-0003). Traefik stays (it provides the IngressRoute/
# Middleware CRDs the edge uses). Ports 8080/8443 map the loadbalancer.
#
# Proxy-free unless YOUR shell is proxied — no proxy value lives in the repo. The
# node's containerd needs the proxy at create time (it inherits nothing else); the
# create block below reads it from your exported HTTP(S)_PROXY and injects it, so a
# clean shell makes a pristine cluster. See docs/dev-loop.md ("HTTP proxies").
#
# Local image registry (ADR-0016 parity): repo-built images (services, lowdefy) have
# no CI/ghcr locally, so Argo has nothing to pull. k3d-registry.localhost:5000 is the
# local stand-in for CI — cluster:full builds+pushes to it, the local values overlays
# point at it, and Argo pulls exactly as prod pulls from ghcr. Wired via --registry-use
# at create time, so an existing cluster must be recreated once to gain it.
set -euo pipefail

CLUSTER="${CLUSTER:-platform}"
REGISTRY="registry.localhost" # container becomes k3d-${REGISTRY}, host k3d-registry.localhost

if ! k3d registry list | awk '{print $1}' | grep -qx "k3d-${REGISTRY}"; then
  echo "→ creating k3d registry 'k3d-${REGISTRY}:5000'"
  k3d registry create "$REGISTRY" --port 5000
fi

if ! k3d cluster list | awk '{print $1}' | grep -qx "$CLUSTER"; then
  echo "→ creating k3d cluster '$CLUSTER'"
  # Node proxy (opt-in, no value baked in). The node's containerd inherits nothing
  # from the host, so a proxy reaches it only via create-time -e flags. We read it
  # from YOUR shell instead of hardcoding one machine's setup: a clean shell (no
  # HTTP(S)_PROXY) creates a pristine cluster; a proxied shell gets its proxy
  # injected, with loopback rewritten to host.k3d.internal (how the node addresses
  # the host). Export HTTP_PROXY/HTTPS_PROXY once, system-side, before first run.
  proxy_flags=()
  host_proxy="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
  if [ -n "$host_proxy" ]; then
    node_proxy="${host_proxy//127.0.0.1/host.k3d.internal}"
    node_proxy="${node_proxy//localhost/host.k3d.internal}"
    no_proxy="localhost,127.0.0.1,.localhost,k3d-registry.localhost,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.svc.cluster.local,cluster.local,.localtest.me"
    proxy_flags=(
      -e "HTTP_PROXY=${node_proxy}@server:*"
      -e "HTTPS_PROXY=${node_proxy}@server:*"
      -e "NO_PROXY=${no_proxy}@server:*"
    )
    echo "  · proxied shell detected → wiring node proxy ${node_proxy}"
  fi
  # registry-qps/burst=0 (unlimited) disables kubelet's per-registry image-pull
  # rate limiter. Its default (5 qps / 10 burst) exists to spare PUBLIC registries;
  # against our OWN local registry it just throttles cold/mass reschedules into a
  # "pull QPS exceeded" storm that adds minutes of backoff. Create-time only.
  #
  # eviction-hard pinned at 2% free (both filesystems): a developer disk often sits
  # near-full, and kubelet's stock disk-pressure threshold (taints ~10-15% free)
  # then evicts the WHOLE platform over a few spare GB. Pinning it low keeps pods
  # put until the disk is genuinely almost-full — and pins it so a recreate (or a
  # distro whose default differs from k3s') can't silently raise it. Explicit set,
  # so inode-based eviction is intentionally out of scope here.
  #
  # image-gc-high/low-threshold (98/80% imagefs used) makes kubelet reclaim unused
  # images only once the image filesystem is 98% full, down to 80%. A developer disk
  # here often shares one near-full partition with the k3d node's imagefs, so a lower
  # high-water mark just makes kubelet log perpetual ImageGCFailed/FreeDiskSpaceFailed
  # warnings — it keeps trying to shed layers that are all in-use, freeing nothing.
  # Pinning high at 98 (level with the eviction floor) silences that noise on a busy
  # disk; GC still fires as a last resort right before eviction would.
  k3d cluster create "$CLUSTER" \
    --servers 1 --agents 0 \
    --port "8080:80@loadbalancer" --port "8443:443@loadbalancer" \
    --k3s-arg '--flannel-backend=none@server:*' \
    --k3s-arg '--disable-network-policy@server:*' \
    --k3s-arg '--kubelet-arg=registry-qps=0@server:*' \
    --k3s-arg '--kubelet-arg=registry-burst=0@server:*' \
    --k3s-arg '--kubelet-arg=eviction-hard=imagefs.available<2%,nodefs.available<2%@server:*' \
    --k3s-arg '--kubelet-arg=image-gc-high-threshold=98@server:*' \
    --k3s-arg '--kubelet-arg=image-gc-low-threshold=80@server:*' \
    --registry-use "k3d-${REGISTRY}:5000" \
    ${proxy_flags[@]+"${proxy_flags[@]}"}
else
  echo "→ cluster '$CLUSTER' exists; starting it (no-op if already running)"
  k3d cluster start "$CLUSTER"
fi

kubectl config use-context "k3d-${CLUSTER}"

# Re-stamp the host-only frontend edge glue on every start. It is not GitOps-managed,
# so a stop/start otherwise comes back without the catch-all `frontend` route (404 at
# /) or with a stale docker-bridge address. No-op on a brand-new cluster whose Traefik
# CRDs aren't up yet — cluster:full re-runs it once the platform is synced.
CLUSTER="$CLUSTER" bash scripts/cluster-edge-glue.sh

echo "✓ cluster '$CLUSTER' ready (context k3d-${CLUSTER})"
