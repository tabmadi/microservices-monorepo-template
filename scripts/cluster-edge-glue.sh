#!/usr/bin/env bash
# Host-only edge glue: routes the product apex (https://dev.localtest.me:8443) to a
# natively-run frontend (`next dev` on :3000) and the Kratos public API (ADR-0009/
# 0010/0014). Deliberately NOT GitOps-managed — prod deploys the frontend in-cluster,
# and infra/gateway is what ArgoCD syncs. This is per-machine state that must be
# re-applied on every cluster START, not just at cluster:full time, for two reasons:
#   • the catch-all `frontend` IngressRoute is not persisted by Argo, so a stop/start
#     or reboot loses it → Traefik answers `404 page not found` at `/`;
#   • the frontend-dev EndpointSlice points at the docker-bridge gateway IP (the only
#     host address a pod can reach), which can change across a k3d restart → a stale
#     address gives a 502. Re-reading it every run self-heals both.
# Idempotent; safe to run any time the cluster is up. Called by cluster-ensure.sh
# (start path), cluster-heal.sh (reboot recovery), cluster-full.sh (bring-up) and
# cluster-edge.sh (the `edge` profile) — hence the hidden `cluster:edge-glue` task:
# you never need to invoke it by hand except to self-heal a 404/502 at `/`.
#
# NOT to be confused with cluster-edge.sh, which is the `edge` PROFILE (ADR-0016):
# a whole tier. This is the per-machine seam underneath it.
set -euo pipefail

CLUSTER="${CLUSTER:-platform}"
NS="${NS:-platform}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
k() { kubectl --context "k3d-${CLUSTER}" "$@"; }

# Traefik installs asynchronously on a fresh k3d cluster, so its IngressRoute CRD may
# not be registered yet on the first ensure of a brand-new cluster. Skip cleanly if
# so — the route is unusable without Traefik anyway, and cluster:full re-runs this
# once the platform is up. On a restart the CRD is already persisted, so we apply.
if ! k get crd ingressroutes.traefik.io >/dev/null 2>&1; then
  echo "· traefik.io CRDs not present yet — skipping edge glue (applied later by cluster:full)"
  exit 0
fi

echo "→ applying host-specific edge glue"
k apply -f infra/local/edge-auth.yaml

# Stamp the EndpointSlice at the CURRENT docker-bridge gateway (the host, as seen
# from a pod). Re-read every run so a bridge-IP change across restarts self-heals.
GW="$(docker inspect "k3d-${CLUSTER}-server-0" \
  --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}')"
if [ -z "$GW" ]; then
  echo "✗ could not determine docker-bridge gateway for k3d-${CLUSTER}-server-0" >&2
  exit 1
fi
k apply -f - <<EOF
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: frontend-dev
  namespace: ${NS}
  labels:
    kubernetes.io/service-name: frontend-dev
addressType: IPv4
ports:
  - name: http
    port: 3000
    protocol: TCP
endpoints:
  - addresses: ["${GW}"]
    conditions: { ready: true }
EOF
echo "✓ edge glue applied (frontend → host ${GW}:3000)"
