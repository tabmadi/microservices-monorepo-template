#!/usr/bin/env bash
# Full local platform via ArgoCD (ADR-0004, ADR-0016) — backs `mise run cluster:full`.
# The heavy lifting
# (CRD→operator→instance ordering, secret materialisation, sync waves) is ArgoCD's
# job, the same tool prod runs; this script only does what Argo cannot bootstrap:
# create the cluster, install the CNI + Argo itself, plant the SOPS decryption key,
# apply the local root-app, then wait and wire the host-specific edge tail.
#
# Baseline (choice a): Argo syncs committed master from GitHub — CI-built images,
# identical to prod. To iterate on uncommitted code/infra, see service:deploy /
# platform:deploy, or point the local root-app targetRevision at a pushed branch.
#
# Teardown: mise run cluster:stop (stop) / mise run cluster:delete (delete).
set -euo pipefail

CLUSTER="${CLUSTER:-platform}"
NS="platform"
DOMAIN="${DOMAIN:-dev.localtest.me}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

k() { kubectl --context "k3d-${CLUSTER}" "$@"; }
h() { helm --kube-context "k3d-${CLUSTER}" "$@"; }
# argocd CLI in core mode: talks straight to the Application CRDs (no `argocd
# login` / argocd-server, ADR-0004). Core mode derives the install namespace from
# the kube-context, so it runs against a throwaway kubeconfig pinned to `argocd`
# (set up in step 5) rather than mutating the user's real context.
ac() { KUBECONFIG="$AC_KUBECONFIG" argocd --core "$@"; }

# 1. Cluster + CNI (a CNI must exist before Argo's pods can schedule).
bash scripts/cluster-ensure.sh
# On a proxied network the node's containerd can wedge pulling the large Cilium /
# ArgoCD images through privoxy, stalling the `helm --wait` steps below (which run
# before Argo, so cluster:unwedge can't rescue them). CLUSTER_PRELOAD=1 warms those
# images on the host first. Off by default — clean networks never need it.
if [ "${CLUSTER_PRELOAD:-0}" = "1" ]; then
  echo "→ CLUSTER_PRELOAD=1: preloading bootstrap-critical images"
  bash scripts/cluster-preload-images.sh
fi
bash scripts/cilium-install.sh

# 2. ArgoCD (it cannot sync itself into existence). Excluded from the local
#    platform ApplicationSet, so this imperative release is authoritative.
echo "→ installing ArgoCD"
helm dependency update infra/helm/platform/argocd >/dev/null
h upgrade --install argocd infra/helm/platform/argocd -n argocd --create-namespace --timeout 8m
k -n argocd rollout status deploy/argocd-server --timeout=300s
k -n argocd rollout status deploy/argocd-repo-server --timeout=300s
k -n argocd rollout status deploy/argocd-applicationset-controller --timeout=300s

# 3. SOPS decryption key (the bootstrap root of trust): the committed throwaway
#    local age key, planted as the Secret the sops-operator mounts (ADR-0005).
echo "→ planting sops-age-key (local throwaway key)"
k create namespace "$NS" --dry-run=client -o yaml | k apply -f -
k -n "$NS" create secret generic sops-age-key \
  --from-file=keys.txt=infra/gitops/platform/local/age.key \
  --dry-run=client -o yaml | k apply -f -

# 3b. Grafana's `grafana-dashboards` ConfigMap (observability chart values
#     dashboardsConfigMaps.default) is now GitOps-managed, not materialised here:
#     the local root-app syncs infra/gitops/local-bootstrap/app-grafana-dashboards.yaml,
#     a Kustomize app that generates it from infra/observability/dashboards/*.json at
#     sync-wave 2 — before the core tier (wave 3) starts Grafana, which mounts it
#     (ADR-0011). A PR that adds or edits a dashboard now reaches the cluster on the
#     next Argo pass, instead of needing an imperative `kubectl create configmap`.

# 3c. Build + push repo images to the local registry — the local stand-in for CI.
#     Argo then deploys services + lowdefy from the registry exactly as prod pulls
#     from ghcr; the only difference is the registry host in the values overlay
#     (ADR-0016). Must run before step 4 so images exist before Argo creates pods.
#     Build args mirror scripts/service-deploy.sh.
REG="k3d-registry.localhost:5000"
# Push over the loopback host, not REG. Docker picks HTTP-vs-HTTPS by resolving the
# registry hostname and checking the result against its insecure-registry CIDRs
# (127.0.0.0/8, ::1/128 by default). k3d's registry only speaks plain HTTP, so the
# push works only if the name resolves into those CIDRs — which depends on each dev's
# NSS setup mapping *.localhost to loopback (e.g. myhostname). Where it doesn't,
# k3d-registry.localhost resolves elsewhere and docker demands TLS: "server gave HTTP
# response to HTTPS client". 127.0.0.1 sidesteps all of that (loopback is insecure on
# every daemon, no per-machine daemon.json). Both names address the same registry
# container and blobs are keyed by repo path, so REG stays the cluster-facing pull
# name in the values overlays; only the push target differs.
PUSH_REG="127.0.0.1:5000"
build_push() { # <image-name> <dockerfile> <context> [extra docker build args…]
  local name="$1" dockerfile="$2" context="$3"
  shift 3
  # Behind a slow proxy, buildkit's fetch of the Dockerfile frontend + base images
  # (docker.io) trips TLS-handshake timeouts intermittently; the layers it did get
  # are cached, so a retry rides over the transient failure. Fails loudly if all
  # attempts miss — same explicit retry the unwedge script uses for host pulls.
  local attempt
  for attempt in 1 2 3; do
    if docker build -t "${PUSH_REG}/${name}:local" -f "$dockerfile" "$@" "$context" &&
      docker push "${PUSH_REG}/${name}:local"; then
      return 0
    fi
    echo "    (build/push of ${name} attempt ${attempt} failed — retrying)"
  done
  echo "✗ could not build+push ${name} after 3 attempts" >&2
  return 1
}
echo "→ building + pushing repo images to ${REG}"
# Build identity baked into each image (ADR-0013): the working-tree SHA (+ -dirty),
# so /version and the X-App-Version header report exactly what this run deployed.
REV="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
git diff --quiet 2>/dev/null || REV="${REV}-dirty"
BUILD_ID=(--build-arg "GIT_SHA=${REV}" --build-arg BUILD_VERSION=local
  --build-arg "BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)")
for svc in authz catalog orders orgs payment; do
  build_push "${svc}-server" "services/${svc}/Dockerfile" . \
    --build-arg SERVICE="${svc}" --build-arg APP_CMD=server "${BUILD_ID[@]}"
done
for svc in orders orgs payment; do
  build_push "${svc}-worker" "services/${svc}/Dockerfile" . \
    --build-arg SERVICE="${svc}" --build-arg APP_CMD=worker "${BUILD_ID[@]}"
done
build_push admin apps/admin/Dockerfile apps/admin

# 4. Local root App-of-Apps → Argo discovers the local appsets + apps from git.
echo "→ applying local root application"
k apply -f infra/gitops/local-bootstrap/root-application.yaml

# 5. Wait for Argo to converge with `argocd app wait` — it blocks in the
#    foreground, streams per-resource sync/health as it changes, and exits
#    non-zero with the offending resource the moment a sync operation fails
#    (no silent wait to the timeout). Two phases because apps are generated
#    asynchronously: first the root app (its AppProject + 2 child apps [secrets,
#    gateway] + 4 appsets [platform-base/data/core, services]), then
#    every app the appsets produced. Appset generation lags appset sync, so the
#    set is re-listed until stable.
echo "→ waiting for ArgoCD to converge (this is a full platform; first run is slow)…"
AC_KUBECONFIG="$(mktemp)"
trap 'rm -f "$AC_KUBECONFIG"' EXIT
k config view --minify --flatten >"$AC_KUBECONFIG"
kubectl --kubeconfig "$AC_KUBECONFIG" config set-context --current --namespace argocd >/dev/null

# `cluster:stop` freezes cluster state mid-sync; on resume, the ArgoCD controller
# reattaches to whatever sync operation was still "Running" and reuses the task
# plan (incl. per-resource sync-waves) it computed back when that operation
# started — even if the manifests (and their wave annotations) have since
# changed. That stale plan can never converge. If the wait times out, that's the
# first thing to suspect: terminate the wedged operation and force a fresh one
# (which recomputes the plan against current git) before giving up for real.
wait_apps() {
  local timeout="$1"
  shift
  if ac app wait "$@" --sync --health --operation --timeout "$timeout"; then
    return 0
  fi
  echo "⚠ one or more of [$*] did not converge in ${timeout}s — terminating their operations (likely stale from a prior cluster:stop) and forcing a fresh sync"
  local app
  for app in "$@"; do ac app terminate-op "$app" || true; done
  for app in "$@"; do ac app sync "$app" --timeout "$timeout"; done
  ac app wait "$@" --sync --health --operation --timeout "$timeout"
}

wait_apps 600 local-root
while :; do
  apps="$(ac app list -o name)"
  # shellcheck disable=SC2086  # names are newline-separated, intentional split
  wait_apps 1800 $apps
  [ "$(ac app list -o name)" = "$apps" ] && break
done
echo "✓ all ArgoCD applications Synced + Healthy"

# 6. Host-specific edge tail (cannot be GitOps — depends on per-machine state):
#    local Traefik tuning, plus the /auth + landing routes to a host-run frontend
#    and the frontend-dev EndpointSlice. The latter two live in cluster-edge-glue.sh so
#    the start path (cluster-ensure.sh) and reboot recovery (cluster-heal.sh) can
#    re-stamp them too — otherwise a stop/start drops the `frontend` route (404 at /).
k apply -f infra/local/traefik-config.yaml
bash scripts/cluster-edge-glue.sh

cat <<EOF

✓ cluster:full up (ArgoCD-driven from master).
  Product (Traefik):  https://${DOMAIN}:8443/api/<resource>/   (flat namespace, self-signed TLS)
  Ops tier (ADR-0017; coarse gate = operator claim + AAL2, no OpenFGA call):
    Grafana:          https://grafana.ops.${DOMAIN}:8443/
    Hubble UI (map):  https://hubble.ops.${DOMAIN}:8443/
    Temporal UI:      https://temporal.ops.${DOMAIN}:8443/
    MinIO console:    https://minio.ops.${DOMAIN}:8443/  (login: minio / minio-password)
    Lowdefy console:  https://lowdefy.ops.${DOMAIN}:8443/
    ArgoCD:           https://argocd.ops.${DOMAIN}:8443/
    Headlamp (k8s):   https://headlamp.ops.${DOMAIN}:8443/   (read-only debug UI)
    pgweb (DB):       https://pgweb.ops.${DOMAIN}:8443/    (read-only DB inspector)
  Frontend:           run it natively on :3000 (the frontend-dev EndpointSlice
                      routes /auth + landing to the host).
  Diagnose:           argocd --core --kube-context k3d-${CLUSTER} app get <app>
                      UI: kubectl -n argocd port-forward svc/argocd-server 8080:443
  Break-glass:        auth plane down? reach any tool via kubectl port-forward with
                      your kubeconfig — the sanctioned bypass (docs/ops/break-glass.md),
                      e.g. kubectl -n platform port-forward svc/grafana 3000:80
  Teardown:           mise run cluster:stop  (keep cache) / cluster:delete (delete)
EOF
