# shellcheck shell=bash
# The local cluster (ADR-0600): identity, shared helpers, and one function per
# bring-up stage. Source it, don't execute — scripts/cluster.sh is the entrypoint.
#
# A stage is convergent: it checks its own post-condition, returns when it holds,
# and otherwise makes it hold. That is what lets one `up` verb create, resume and
# repair a cluster. `forced <stage>` skips the fast-exit, which is all `heal` is.
#
# A tier is a stage list, not a branch (ADR-0205). The lists live in cluster.sh.

# shellcheck disable=SC2317  # the guard's `return` is reached when re-sourced.
if [[ -n "${__CLUSTER_SH_LOADED:-}" ]]; then return 0 2>/dev/null || true; fi
__CLUSTER_SH_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# This machine's egress, written by proxy:setup and absent on a direct network. It is
# loaded rather than computed: kind reads the proxy variables from its own environment
# and is the only thing that can add the node's name to NO_PROXY, which the API server
# call inside the node needs — without it `kind create` aborts on an EOF.
if [ -f "$ROOT/infra/local/proxy.local.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$ROOT/infra/local/proxy.local.env"
  set +a
fi
CLUSTER="${CLUSTER:-platform}"
NS="${NS:-platform}"
DOMAIN="${DOMAIN:-dev.localtest.me}"
KIND_CONFIG="infra/local/kind.yaml"
REGISTRY="registry.localhost"
ZOT_IMAGE="ghcr.io/project-zot/zot-linux-amd64:v2.1.20"
FORCE="${FORCE:-}"

# Validated at source time, not inside cluster_ctx: the functions are called as
# `$(cluster_ctx)`, where an exit kills only the subshell and the caller carries on
# against whatever the current kube-context happens to be. Empty is allowed here and
# resolved below, once the functions the resolution needs exist.
case "${TIER:-}" in
"" | base | full) ;;
*) fail "'${TIER}' is not a tier — use \"base\" or \"full\"" ;;
esac

cluster_tier() { printf '%s' "$TIER"; }
# The tier is an argument, so a message naming a command names its tier too.
up_hint() {
  if [ "$TIER" = full ]; then printf 'mise run cluster:up -- full'; else printf 'mise run cluster:up'; fi
}
# The full tier's name carries the tier, so `docker ps` and `kubectl config
# get-contexts` both say which cluster is which.
cluster_name_of() {
  if [ "$1" = full ]; then printf '%s-full' "$CLUSTER"; else printf '%s' "$CLUSTER"; fi
}
cluster_name() { cluster_name_of "$TIER"; }
other_tier() { if [ "$TIER" = full ]; then printf 'base'; else printf 'full'; fi; }
cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$1"; }
# A tier-scoped verb that found nothing says so, and names the tier that is up: the
# tiers are alternatives, so "no such cluster" is usually the wrong tier named.
other_tier_hint() {
  local other
  other="$(other_tier)"
  cluster_exists "$(cluster_name_of "$other")" &&
    detail "the ${other} tier is up — did you mean 'mise run cluster:${1} -- ${other}'?"
  return 0
}
cluster_ctx() { printf 'kind-%s' "$(cluster_name)"; }

# Is this cluster's node up, as opposed to merely created? Both tiers can exist at
# once; only one can hold the edge ports, so only one is ever serving.
cluster_running() {
  docker inspect -f '{{.State.Running}}' "${1}-control-plane" 2>/dev/null | grep -qx true
}

# The tier that is up, or nothing. Running beats merely created, and an ambiguous
# answer is no answer: a caller that has to guess between two clusters must be told
# which one it meant rather than be given one of them.
detect_tier() {
  # One listing for both tiers: this runs on every source, and `kind get clusters`
  # is a docker round-trip. `if`, not `&&`, so a stopped cluster is an answer rather
  # than a non-zero status that ends the caller under `set -e`.
  local tier name clusters running=() present=()
  clusters="$(kind get clusters 2>/dev/null || true)"
  for tier in base full; do
    name="$(cluster_name_of "$tier")"
    printf '%s\n' "$clusters" | grep -qx "$name" || continue
    present+=("$tier")
    if cluster_running "$name"; then running+=("$tier"); fi
  done
  if [ "${#running[@]}" -eq 1 ]; then
    printf '%s' "${running[0]}"
  elif [ "${#running[@]}" -eq 0 ] && [ "${#present[@]}" -eq 1 ]; then
    printf '%s' "${present[0]}"
  else
    return 1
  fi
}

# WHICH TIER a script acts on, for every script that is not cluster.sh.
#
# Only cluster.sh chooses a tier: it takes one as an argument and creates it. Every
# other script here acts on a cluster someone else already brought up, and naming a
# tier is not its call to make — so the default is read off the machine rather than
# fixed to a constant. A constant is wrong half the time and wrong silently: with
# `base` hardcoded, a script run against a live full tier resolved to context
# `kind-platform`, every kubectl in it failed against a context that does not exist,
# and the failure read as "the platform is down" while the platform served traffic.
#
# Precedence, highest first:
#
#   TIER in the environment  a caller naming a tier on purpose, including a stopped
#                            one. cluster.sh exports it so its stages inherit it.
#   TIER_FROM_ARGV=1         cluster.sh, which parses the tier out of argv after
#                            this file is sourced, and whose bare `up` means base.
#   the tier that is up      the only cluster there is to act on.
#   base                     nothing is up, or both are: the tier the docs create
#                            first, so "not created" names the command to run.
if [ -z "${TIER:-}" ] && [ -z "${TIER_FROM_ARGV:-}" ]; then
  TIER="$(detect_tier || true)"
fi
TIER="${TIER:-base}"
# Exported, because stages shell out to scripts that resolve the context from it.
# Unexported, `identity-seed.sh` seeds the inner loop while the full tier waits.
export TIER

k() { kubectl --context "$(cluster_ctx)" "$@"; }
h() { helm --kube-context "$(cluster_ctx)" "$@"; }

forced() { [[ ",${FORCE}," == *",$1,"* ]]; }

# Poll until a command succeeds. Bespoke readiness loops are how the two tiers drifted.
wait_for() { # <what> <seconds> <cmd…>
  local what="$1" budget="$2"
  shift 2
  local waited=0
  until "$@" >/dev/null 2>&1; do
    [ "$waited" -ge "$budget" ] && fail "timed out after ${budget}s waiting for ${what}"
    sleep 2
    waited=$((waited + 2))
  done
}

# `build` is the offline path and needs the dependency's repo already registered in
# the caller's helm config; `update` resolves it from Chart.yaml. Developer machines
# pass on the first, clean runners only on the second.
chart_deps() { helm dependency build "$1" >/dev/null 2>&1 || helm dependency update "$1" >/dev/null; }

# A tool that is absent reads as an answer: `kind get clusters` failing looks
# exactly like a cluster that was never created, and every probe below inherits
# that ambiguity. Assert the tools first, so "not found" cannot mean "not created".
require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 ||
      fail "${tool} not found on PATH — run this through mise (\`mise run …\`), which puts the pinned toolchain there"
  done
}

# Fail unless the probe CAN run. An unreachable cluster otherwise looks identical to
# "not deployed" to every idempotence guard.
require_cluster() {
  require_tools kubectl
  k cluster-info >/dev/null 2>&1 ||
    fail "cluster $(cluster_ctx) is not reachable — run '$(up_hint)' first"
}

# The Application managing a service, or nothing. The committed ApplicationSet named
# apps after the values FILE and now trims the extension, so both spellings are live
# in clusters bootstrapped from different commits; guessing one silently leaves
# auto-sync unpaused, and Argo reverts the deploy that just reported success.
argo_service_app() {
  local name
  for name in "local-service-${1}" "local-service-${1}.yaml"; do
    if k -n argocd get application.argoproj.io "$name" >/dev/null 2>&1; then
      echo "$name"
      return 0
    fi
  done
}

# ── Stages ────────────────────────────────────────────────────────────────────

# zot, the registry every environment runs (ADR-0105), as a host container beside
# both clusters. It mirrors the upstreams on demand, so nothing is preloaded and no
# image list has to be maintained. Host-level: it survives cluster delete/recreate.
stage_registry() {
  if ! docker inspect "$REGISTRY" >/dev/null 2>&1; then
    step "creating the local registry '${REGISTRY}:5000' (zot)"
    # The image's default command names a config.json; this config is YAML.
    docker run -d --restart=always --name "$REGISTRY" \
      -p 127.0.0.1:5000:5000 \
      -v "${ROOT}/infra/local/zot-config.yaml:/etc/zot/config.yaml:ro" \
      -v "${REGISTRY}-data:/var/lib/zot" \
      "$ZOT_IMAGE" serve /etc/zot/config.yaml >/dev/null
  elif [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY")" != true ]; then
    step "starting the local registry '${REGISTRY}'"
    docker start "$REGISTRY" >/dev/null
  fi
  # A restarting registry is one every pull misses, and the failure lands later, on
  # a pod.
  local waited=0
  until [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY" 2>/dev/null)" = true ]; do
    [ "$waited" -ge 30 ] && fail "the registry '${REGISTRY}' is not running:
$(docker logs --tail 5 "$REGISTRY" 2>&1 | sed 's/^/    /')"
    sleep 1
    waited=$((waited + 1))
  done
}

# Fill zot with every third-party image the cluster will pull, BEFORE the cluster
# exists (ADR-0105).
#
# zot's on-demand sync copies a whole image before it answers the manifest request,
# so a cold pull costs tens of seconds. Left to the cluster, ~18 pods request their
# images at once, zot saturates, and every one of them exceeds containerd's pull
# deadline and backs off — while zot goes on caching images nobody is waiting for
# any more. Warming is the same work, done once, sequentially, with nothing waiting.
#
# The list is generated and committed (`mise run gen:image-allowlist`), from the same
# render that produces Kyverno's allow-list, so the warm set and the admitted set
# cannot disagree.
stage_warm() {
  local refs="infra/local/image-refs.txt" total warmed=0 fetched=0
  local missed=()
  [ -f "$refs" ] || fail "${refs} is missing — run 'mise run gen:image-allowlist'"
  total="$(grep -cvE '^#|^$' "$refs")"
  step "warming the registry with ${total} third-party image(s)"

  local ref host path reference name tag
  while read -r ref; do
    # Split the reference the way a registry client does.
    host=docker.io
    path="$ref"
    if [[ "$ref" == */* ]]; then
      name="${ref%%/*}"
      # A first segment is a REGISTRY only if it looks like a host. `alpine/k8s` is
      # a Docker Hub repository; `quay.io/cilium/cilium` is not.
      if [[ "$name" == *.* || "$name" == *:* || "$name" == localhost ]]; then
        host="$name"
        path="${ref#*/}"
      fi
    fi
    reference=""
    if [[ "$path" == *@* ]]; then
      reference="${path#*@}"
      path="${path%@*}"
    fi
    name="${path##*/}"
    tag=""
    if [[ "$name" == *:* ]]; then
      tag="${name##*:}"
      path="${path%:*}"
    fi
    # Docker Hub keeps its own images under `library/`.
    [ "$host" != docker.io ] || [[ "$path" == */* ]] || path="library/${path}"
    [ -n "$reference" ] || reference="$tag"

    # The tags API is sufficient only for an unpinned reference. A cached tag can
    # coexist with an absent platform digest, which defers the download until pods
    # pull concurrently and exceed containerd's deadline.
    if [[ "$ref" != *@* ]] && [ -n "$tag" ] && curl -sf --noproxy '*' --max-time 10 \
      "http://127.0.0.1:5000/v2/${path}/tags/list" 2>/dev/null |
      yq -e ".tags // [] | contains([\"${tag}\"])" >/dev/null 2>&1; then
      warmed=$((warmed + 1))
      continue
    fi

    detail "· ${ref}"
    if curl -sf -o /dev/null --noproxy '*' --max-time 900 \
      -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json' \
      "http://127.0.0.1:5000/v2/${path}/manifests/${reference}?ns=${host}"; then
      fetched=$((fetched + 1))
    else
      missed+=("$ref")
    fi
  done < <(grep -vE '^#|^$' "$refs")

  ok "registry warm: ${warmed} already cached, ${fetched} fetched"
  if [ "${#missed[@]}" -gt 0 ]; then
    printf '    · %s\n' "${missed[@]}" >&2
    fail "${#missed[@]} image(s) above could not be cached. The nodes pull only from
  this registry, so the cluster cannot start without them. Re-run to retry; if it
  persists, check egress with 'mise run proxy:setup -- --check'."
  fi
}

# The kind cluster: create it, or start every node it already has. A stopped
# multi-node cluster comes back with its workers down, and a control plane alone
# reports Ready while nothing schedules.
stage_cluster() {
  local name other
  name="$(cluster_name)"

  # The tiers share the edge's host ports, so they are alternatives. Name the
  # conflict rather than letting docker report a bind failure from inside a
  # half-created cluster.
  other="$(cluster_name_of "$(other_tier)")"
  if cluster_exists "$other" && cluster_running "$other"; then
    fail "cluster '${other}' is running and holds the edge ports 8080/8443.
  Run one tier at a time:
    mise run cluster:stop -- $([ "$TIER" = full ] && echo base || echo full)"
  fi

  if ! kind get clusters 2>/dev/null | grep -qx "$name"; then
    step "creating kind cluster '${name}' from ${KIND_CONFIG}"
    kind create cluster --name "$name" --config "$KIND_CONFIG"
  else
    local n stopped=0
    mapfile -t nodes < <(kind get nodes --name "$name")
    for n in "${nodes[@]}"; do
      [ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" = false ] && stopped=1
    done
    if [ "$stopped" = 1 ]; then
      step "starting ${#nodes[@]} stopped node(s) of '${name}'"
      for n in "${nodes[@]}"; do docker start "$n" >/dev/null; done
      k wait --for=condition=Ready node --all --timeout=300s
    fi
  fi

  # kind recreates the `kind` docker network with the first cluster, and the nodes
  # resolve registry.localhost through its embedded DNS — so re-attach every run.
  if docker network inspect kind >/dev/null 2>&1 &&
    ! docker inspect "$REGISTRY" \
      --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' | grep -qw kind; then
    step "attaching ${REGISTRY} to the kind network"
    docker network connect kind "$REGISTRY"
  fi

  kubectl config use-context "$(cluster_ctx)" >/dev/null
}

# Cilium (ADR-0206). The cluster is created with disableDefaultCNI, so nothing
# schedules until this runs.
stage_cni() {
  if ! forced cni && h -n kube-system status cilium >/dev/null 2>&1 &&
    k get node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    return 0
  fi

  # The one value the local tiers override. The CONTAINER NAME, because loopback is
  # the API server on the control plane only (a worker's agent would never connect)
  # and a node's docker IP moves across restarts. It resolves through docker's
  # embedded DNS from the host netns the agent runs in, so it needs no CNI.
  local apiserver
  apiserver="$(cluster_name)-control-plane"
  step "installing Cilium (apiserver ${apiserver}:6443)"
  chart_deps infra/helm/platform/cilium
  h upgrade --install cilium infra/helm/platform/cilium -n kube-system \
    --set cilium.operator.replicas=1 \
    --set "cilium.k8sServiceHost=${apiserver}" \
    --set cilium.k8sServicePort=6443 \
    --timeout 5m
  k wait --for=condition=Ready node --all --timeout=600s

  # hubble-peer is backed by the agent's own hostPort. On a stop/start the agent
  # goes briefly NotReady, Cilium quarantines the sole backend, and — because LB
  # state is restored from the pinned bpf map — never re-reconciles it, wedging
  # hubble-relay for good. The chart exposes no knob for this.
  k -n kube-system patch svc hubble-peer --type merge \
    -p '{"spec":{"publishNotReadyAddresses":true}}' >/dev/null
  ok "Cilium installed; node Ready"
}

# `dev.localtest.me` is public DNS pointing at 127.0.0.1 — right on the host, wrong
# in a pod, where it is the pod's own loopback. Rewriting the NAME (rather than
# using a Service DNS name) keeps the request carrying the host and SNI the
# IngressRoutes match on and the wildcard cert is issued for.
stage_coredns() {
  local corefile patched
  corefile="$(k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
  if ! forced coredns && printf '%s' "$corefile" | grep -q "name exact ${DOMAIN}"; then
    return 0
  fi

  step "rewriting ${DOMAIN} to the edge in CoreDNS"
  local stanza="rewrite stop {
    name exact ${DOMAIN} traefik.kube-system.svc.cluster.local
    answer auto
}
rewrite stop {
    name regex (.*)\\.${DOMAIN//./\\.} traefik.kube-system.svc.cluster.local
    answer auto
}"
  # kind's Corefile always opens with the default `.:53 {` block.
  patched="$(printf '%s\n' "$corefile" |
    awk -v stanza="$stanza" 'NR == 1 { print; print stanza; next } { print }')"
  k -n kube-system create configmap coredns --from-literal="Corefile=$patched" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n kube-system rollout restart deploy/coredns >/dev/null
  k -n kube-system rollout status deploy/coredns --timeout=180s
}

# The namespaces and their Pod Security Admission profile (ADR-0200), from the same
# chart the GitOps tiers sync. Before anything is admitted: PSA is an admission
# check, so a label that lands after the pods governs the next admission, not these.
stage_namespaces() {
  step "applying the namespaces and their pod-security profile"
  h template namespaces infra/helm/platform/namespaces \
    -f infra/gitops/platform/local/values.yaml | k apply -f - >/dev/null
}

# Traefik (ADR-0305). kind ships no ingress controller, and the CRDs it carries must
# be registered before any IngressRoute is applied — by the glue stage below, or by
# the gateway Application on the full tier.
stage_edge() {
  if ! forced edge && h -n kube-system status traefik >/dev/null 2>&1 &&
    k -n kube-system rollout status deploy/traefik --timeout=0 >/dev/null 2>&1; then
    return 0
  fi
  step "installing Traefik (edge controller)"
  # No gitops overlay coalesces here: traefik is imperative-only, absent from the
  # platform ApplicationSet, so the chart's own values carry the NodePort mapping.
  chart_deps infra/helm/platform/traefik
  h upgrade --install traefik infra/helm/platform/traefik -n kube-system --timeout 5m
  k -n kube-system rollout status deploy/traefik --timeout=300s
}

# Per-machine edge glue, deliberately not GitOps-managed: the catch-all `/` route to
# a host-run frontend, and an EndpointSlice pointing at the docker-bridge gateway —
# the only host address a pod can dial. The gateway moves across restarts, so this
# is re-stamped on every start rather than only at bring-up.
stage_glue() { # [<name> <port>]
  k get crd ingressroutes.traefik.io >/dev/null 2>&1 ||
    fail "traefik.io CRDs are not registered — bring the cluster up first"

  local gw name="${1:-frontend}" port="${2:-3000}"
  gw="$(docker inspect "$(cluster_name)-control-plane" \
    --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}')"
  [ -n "$gw" ] || fail "could not read the docker-bridge gateway for $(cluster_name)-control-plane"

  [ "$#" -ge 2 ] || k apply -f infra/local/edge-auth.yaml >/dev/null
  k apply -f - >/dev/null <<EOF
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ${name}-dev
  namespace: ${NS}
  labels:
    kubernetes.io/service-name: ${name}-dev
addressType: IPv4
ports:
  - name: http
    port: ${port}
    protocol: TCP
endpoints:
  - addresses: ["${gw}"]
    conditions: { ready: true }
EOF
  ok "edge glue applied (${name} → host ${gw}:${port})"
}

# Postgres out of the shared dependency manifest. Temporal and OpenFGA live in the
# same file and are skipped by label — they are opt-in, added by the services that
# declare them. Postgres is in the floor because Kratos needs a store.
stage_postgres() {
  step "applying the postgres dependency stand-in (Kratos's store)"
  k apply -f infra/local/deps.yaml -l 'local.platform/component=postgres' >/dev/null
  k -n "$NS" rollout status deploy/postgres --timeout=180s
}

# cert-manager and the self-signed wildcard issuer. TWO passes, because one release
# cannot satisfy both orderings Helm gives us neither of: the CRDs are TEMPLATES of
# the subchart, so a single render validates this chart's own cert-manager.io/v1
# objects against an API server that has never heard of that group; and the webhook
# must be admitting before the Certificates apply. Argo needs neither — sync-waves
# order the issuers after the CRDs.
stage_certs() {
  step "installing cert-manager + the self-signed wildcard issuer"
  chart_deps infra/helm/platform/cert-manager
  h upgrade --install cert-manager infra/helm/platform/cert-manager \
    -n "$NS" --create-namespace --timeout 5m --wait \
    -f infra/gitops/platform/local/values.yaml --set issuers.enabled=false
  k -n "$NS" rollout status deploy/cert-manager-webhook --timeout=180s

  local attempt
  for attempt in 1 2 3; do
    h upgrade --install cert-manager infra/helm/platform/cert-manager \
      -n "$NS" --create-namespace --timeout 5m --wait \
      -f infra/gitops/platform/local/values.yaml && break
    [ "$attempt" = 3 ] && fail "cert-manager did not install after 3 attempts"
    detail "waiting for the cert-manager webhook, then retrying"
    k -n "$NS" rollout status deploy/cert-manager-webhook --timeout=180s || true
  done
  k -n "$NS" wait --for=condition=Ready certificate/wildcard --timeout=120s
}

# Only the PriorityClasses (ADR-0204): the service chart sets priorityClassName
# unconditionally, so without them `cluster:add` fails at pod creation. The quotas,
# limit ranges and PDBs in that chart are sized for the full platform.
stage_priority() {
  step "applying the priority classes services are scheduled by"
  h template resource-governance infra/helm/platform/resource-governance \
    -f infra/gitops/platform/local/values.yaml |
    yq 'select(.kind == "PriorityClass")' | k apply -f - >/dev/null
}

# The shared edge middlewares (ADR-0305). Only middlewares.yaml — the rest of
# infra/gateway routes the ops tier, which this tier does not run.
stage_middlewares() {
  step "applying the edge middlewares"
  k apply -n "$NS" -f infra/gateway/middlewares.yaml >/dev/null
}

# Kratos's secrets from the committed local SOPS bundle, with the dsn pointed at the
# stand-in Postgres instead of CNPG.
stage_secrets() {
  # The template ships ONE local age key, so every generated project would share it
  # until someone noticed. This mints a per-project key and re-encrypts the bundle;
  # a project that already has its own is left alone. Ahead of the decrypt, which
  # afterwards needs a key this repository no longer holds.
  bash scripts/rotate-local-age-key.sh

  step "materialising kratos-secrets from the committed local SOPS bundle"
  local secrets dsn
  secrets="$(SOPS_AGE_KEY_FILE=infra/gitops/platform/local/age.key \
    sops -d infra/gitops/platform/local/secrets/platform.enc.yaml |
    yq -o=json '.spec.secretTemplates[] | select(.name == "kratos-secrets") | .stringData')"
  [ -n "$secrets" ] || fail "kratos-secrets not found in the local SOPS bundle"
  dsn="postgres://dev:dev@postgres.${NS}.svc.cluster.local:5432/kratos?sslmode=disable"
  k -n "$NS" create secret generic kratos-secrets \
    --from-literal=secretsDefault="$(jq -r .secretsDefault <<<"$secrets")" \
    --from-literal=secretsCookie="$(jq -r .secretsCookie <<<"$secrets")" \
    --from-literal=secretsCipher="$(jq -r .secretsCipher <<<"$secrets")" \
    --from-literal=smtpConnectionURI="$(jq -r .smtpConnectionURI <<<"$secrets")" \
    --from-literal=dsn="$dsn" --dry-run=client -o yaml | k apply -f - >/dev/null
}

# Kratos + Oathkeeper, wired the way the platform ApplicationSet wires them: the
# canonical infra/auth overlays plus the string artefacts, never inlined into chart
# values (lint:auth-inline).
stage_ory() {
  step "installing kratos + oathkeeper"
  chart_deps infra/helm/platform/ory
  h upgrade --install ory infra/helm/platform/ory \
    -n "$NS" --create-namespace --timeout 8m --wait \
    -f infra/auth/kratos/values.yaml \
    -f infra/auth/oathkeeper/values.yaml \
    -f infra/gitops/platform/local/values.yaml \
    --set-file 'kratos.kratos.identitySchemas.user\.v1\.json=infra/auth/kratos/identity-schemas/user.v1.json' \
    --set-file 'oathkeeper.oathkeeper.accessRules=infra/auth/oathkeeper/access-rules.json'
}

# The committed test identities (ADR-0601) — the same ones the e2e suite uses.
stage_identities() { bash scripts/identity-seed.sh; }

# The bootstrap root of trust (ADR-0202): the committed throwaway local age key,
# planted as the Secret the sops-operator mounts.
stage_sopskey() {
  step "planting sops-age-key (local throwaway key)"
  k -n "$NS" create secret generic sops-age-key \
    --from-file=keys.txt=infra/gitops/platform/local/age.key \
    --dry-run=client -o yaml | k apply -f - >/dev/null
}

# Build + push the repo's images to the local registry — the local stand-in for CI.
# Argo then pulls them exactly as prod pulls from ghcr, the registry host being the
# only difference (ADR-0205). Must precede the root app, or Argo creates pods for
# images that do not exist.
stage_images() {
  local reg="registry.localhost:5000"
  # Docker picks HTTP-vs-HTTPS by resolving the registry name against its
  # insecure-registry CIDRs, so pushing to `registry.localhost` works only where NSS
  # maps *.localhost to loopback. 127.0.0.1 is insecure on every daemon. Both names
  # address the same container and blobs are keyed by repo path, so the overlays
  # keep the cluster-facing name.
  local push_reg="127.0.0.1:5000"
  local rev
  rev="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
  git diff --quiet 2>/dev/null || rev="${rev}-dirty"
  local build_id=(--build-arg "GIT_SHA=${rev}" --build-arg BUILD_VERSION=local
    --build-arg "BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)")

  build_push() { # <image-name> <dockerfile> <context> [build args…]
    local name="$1" dockerfile="$2" context="$3" attempt
    shift 3
    # Buildkit's fetch of the frontend + base images trips TLS-handshake timeouts on
    # a slow link; the layers it did get are cached, so a retry rides over it.
    for attempt in 1 2 3; do
      docker build -t "${push_reg}/${name}:local" -f "$dockerfile" "$@" "$context" &&
        docker push "${push_reg}/${name}:local" && return 0
      detail "build/push of ${name} attempt ${attempt} failed — retrying"
    done
    fail "could not build+push ${name} after 3 attempts"
  }

  step "building + pushing repo images to ${reg}"
  # DERIVED from the values files: the services ApplicationSet generates one
  # Application per file, so a file with no image built for it is an Application
  # stuck in ImagePullBackOff, and the tier is "full" in name only. A hand-written
  # list drifts the moment a service is added or grows a worker, and it did.
  local values svc
  for values in infra/gitops/services/local/values/*.yaml; do
    svc="$(basename "$values" .yaml)"
    # Apps have their own Dockerfile, context and build args; they are built below.
    [ -f "services/${svc}/Dockerfile" ] || continue
    if [ "$(yq -r '.server.enabled // true' "$values")" = true ]; then
      build_push "${svc}-server" "services/${svc}/Dockerfile" . \
        --build-arg SERVICE="${svc}" --build-arg APP_CMD=server "${build_id[@]}"
    fi
    if [ "$(yq -r '.worker.enabled // false' "$values")" = true ]; then
      build_push "${svc}-worker" "services/${svc}/Dockerfile" . \
        --build-arg SERVICE="${svc}" --build-arg APP_CMD=worker "${build_id[@]}"
    fi
  done
  build_push admin apps/admin/Dockerfile apps/admin
  # `output: "standalone"` freezes next.config into server.js, so the server-action
  # CSRF allowlist is decided at BUILD time — read from the values file the pod
  # reads it from at runtime (ADR-0306).
  build_push frontend apps/frontend/Dockerfile . \
    --build-arg "SERVICE_VERSION=${rev}" \
    --build-arg "EDGE_PUBLIC_ORIGIN=$(yq -r '.env.EDGE_PUBLIC_ORIGIN // ""' \
      infra/gitops/services/local/values/frontend.yaml)"
}

# ArgoCD, which cannot sync itself into existence. Excluded from the local platform
# ApplicationSet, so this release is authoritative.
stage_argocd() {
  # The CNI stage cycles the pod network on every run, restarting Kyverno with it.
  # Its webhook is failurePolicy: Fail, so while the admission controller is unready
  # EVERY apply is rejected — starting with Argo's own pre-upgrade hook Job, which
  # fails on a connection-refused naming a webhook and nothing suggesting a wait.
  # Keyed on the DEPLOYMENT, not the namespace: the namespaces stage creates the
  # kyverno namespace in the prelude, so a first bring-up has one before Argo has
  # installed anything into it.
  if k -n kyverno get deploy kyverno-admission-controller >/dev/null 2>&1; then
    step "waiting for the Kyverno admission webhook to serve"
    k -n kyverno rollout status deploy/kyverno-admission-controller --timeout=300s
    # The rollout is the Deployment's view; the API server dials the endpoint, which
    # lags the pod going Ready.
    # shellcheck disable=SC2329  # invoked by name through wait_for.
    kyverno_endpoint_ready() {
      [ -n "$(k -n kyverno get endpointslice -l kubernetes.io/service-name=kyverno-svc \
        -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}')" ]
    }
    wait_for "a ready kyverno endpoint" 120 kyverno_endpoint_ready
  fi

  step "installing ArgoCD"
  chart_deps infra/helm/platform/argocd
  # Machine-local values, written by proxy:setup and absent on a direct network. The
  # repo-server is the one component that reaches git and the chart repositories from
  # inside the cluster, so it is the one that needs the host's egress route.
  local overlay=()
  [ -f infra/local/proxy.local.yaml ] && overlay=(-f infra/local/proxy.local.yaml)
  h upgrade --install argocd infra/helm/platform/argocd -n argocd --create-namespace --timeout 8m "${overlay[@]}"
  k -n argocd rollout status deploy/argocd-server --timeout=300s
  k -n argocd rollout status deploy/argocd-repo-server --timeout=300s
  k -n argocd rollout status deploy/argocd-applicationset-controller --timeout=300s
}

# The local root App-of-Apps, then wait for Argo to converge. Grafana's dashboards
# and every ordering concern are Argo's job, by sync-wave.
stage_rootapp() {
  step "applying the local root application"
  k apply -f infra/gitops/local-bootstrap/root-application.yaml >/dev/null

  # argocd CLI in core mode talks straight to the Application CRDs (ADR-0201) and
  # derives its namespace from the kube-context, so it runs against a throwaway
  # kubeconfig rather than mutating the user's.
  local kubeconfig
  kubeconfig="$(mktemp)"
  # shellcheck disable=SC2064  # expand the path now, not at trap time
  trap "rm -f '$kubeconfig'" RETURN
  k config view --minify --flatten >"$kubeconfig"
  kubectl --kubeconfig "$kubeconfig" config set-context --current --namespace argocd >/dev/null
  ac() { KUBECONFIG="$kubeconfig" argocd --core "$@"; }

  # `cluster:stop` freezes a sync mid-flight; on resume the controller reattaches to
  # that operation and reuses the task plan (sync-waves included) it computed back
  # then, which can never converge against changed manifests. Terminating the
  # operation forces a fresh plan against current git.
  wait_apps() {
    local timeout="$1" app
    shift
    ac app wait "$@" --sync --health --operation --timeout "$timeout" && return 0
    warn "[$*] did not converge in ${timeout}s — terminating their operations (likely stale from a cluster:stop) and re-syncing"
    for app in "$@"; do ac app terminate-op "$app" || true; done
    for app in "$@"; do ac app sync "$app" --timeout "$timeout"; done
    ac app wait "$@" --sync --health --operation --timeout "$timeout"
  }

  step "waiting for ArgoCD to converge (first run is slow)"
  wait_apps 600 local-root
  # Appset generation lags appset sync, so the set is re-listed until stable.
  local apps
  while :; do
    apps="$(ac app list -o name)"
    # shellcheck disable=SC2086  # newline-separated names, intentional split
    wait_apps 1800 $apps
    [ "$(ac app list -o name)" = "$apps" ] && break
  done
  ok "all ArgoCD applications Synced + Healthy"
}

# Fill the in-cluster zot's catalogue with the first-party images (ADR-0105). The
# nodes pull from the host container, so the in-cluster registry a deployed
# environment runs would otherwise sit empty locally and its `zot.ops` console read
# as broken. Best-effort: the console is a convenience and no pod's start depends on
# it, so a copy failure warns and the bring-up carries on.
stage_populatezot() {
  bash "$(dirname "${BASH_SOURCE[0]}")/../populate-zot.sh" ||
    warn "populate-zot did not complete — the in-cluster zot console may be empty (non-fatal)"
}
