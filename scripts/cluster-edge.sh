#!/usr/bin/env bash
# The `edge` local profile (ADR-0016 profiles, ADR-0029) — backs
# `mise run cluster:edge`. The tier for building authenticated UI: the real
# edge and the real identity stack, with application data served by the API mock.
#
#   Traefik · cert-manager · Kratos · Oathkeeper · Postgres   real
#   application services                      replaced by their OpenAPI contract
#   Temporal · OpenFGA · CNPG · observability · ArgoCD   absent
#
# INCOMPLETE: the API mock that serves `/api` is not wired up yet, so this profile
# currently brings up a real edge in front of nothing — every `/api` route 404s
# until the mock lands. Everything else (TLS, Kratos, Oathkeeper, the host edge
# glue, the seeded identities) is real and usable: you can log in for real today.
#
# So the frontend's auth path is byte-identical to production — there is no bypass,
# no development provider, no NODE_ENV branch, because nothing needs one.
#
# A profile is a SELECTION, not a copy: every component here is installed from the
# same chart and the same `infra/gitops/platform/local/values.yaml` overlay that
# cluster:full uses. This script names which ones, and nothing else — there is no
# second values file to drift.
#
# Not ArgoCD-driven, deliberately: Argo is the full tier's engine (ADR-0016), and
# this is an inner-loop tier. Same reasoning as cluster:lite's imperative apply.
#
# Related task: `mise run cluster:edge-glue` re-stamps the host edge glue alone
# (hidden; this script and the start/reboot paths already run it for you).
set -euo pipefail

source "$(dirname "$0")/lib/log.sh"

CLUSTER="${CLUSTER:-platform}"
NS="platform"
DOMAIN="${DOMAIN:-dev.localtest.me}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

k() { kubectl --context "k3d-${CLUSTER}" "$@"; }
h() { helm --kube-context "k3d-${CLUSTER}" "$@"; }

# 1. Cluster + CNI. Same bootstrap floor as every other tier.
bash scripts/cluster-ensure.sh
bash scripts/cilium-install.sh

# 2. Postgres only, out of the shared dependency manifest. Temporal and OpenFGA
#    live in the same file and are skipped by label — they render no page, and the
#    tier's whole point is not paying for them (ADR-0029).
step "applying the postgres dependency stand-in (Kratos's store)"
k apply -f infra/local/deps.yaml -l 'local.platform/component in (base,postgres)'
k -n "$NS" rollout status deploy/postgres --timeout=180s

# 3. TLS. cert-manager IS the mechanism in every environment (ADR-0016); only the
#    issuer differs, and the local values already select the SelfSigned one.
#    Helm applies the chart's ClusterIssuer/Certificates in the same pass that
#    creates the webhook they must be admitted by, so a cold install can lose that
#    race ("no endpoints available for service cert-manager-webhook"). ArgoCD
#    solves it with sync-waves; imperatively the honest fix is to wait for the
#    webhook and apply again — the retry is doing what wave 1 does, not papering
#    over a flake.
step "installing cert-manager + the self-signed wildcard issuer"
h dependency build infra/helm/platform/cert-manager >/dev/null
for attempt in 1 2 3; do
  if h upgrade --install cert-manager infra/helm/platform/cert-manager \
    -n "$NS" --create-namespace --timeout 5m --wait \
    -f infra/gitops/platform/local/values.yaml; then
    break
  fi
  [ "$attempt" = 3 ] && fail "cert-manager did not install after 3 attempts"
  detail "waiting for the cert-manager webhook, then retrying"
  k -n "$NS" rollout status deploy/cert-manager-webhook --timeout=180s || true
done
k -n "$NS" wait --for=condition=Ready certificate/wildcard --timeout=120s

# 4. The shared edge middlewares (ADR-0009): identity-header stripping, Oathkeeper
#    forward-auth, the rate limit, security headers. Only middlewares.yaml — the
#    rest of infra/gateway routes the ops tier, which this profile does not run.
step "applying the edge middlewares"
k apply -n "$NS" -f infra/gateway/middlewares.yaml

# 5. Kratos's secrets. The committed local SOPS bundle is the source (same material
#    cluster:full decrypts through the sops-operator), with one substitution: the
#    dsn points at the stand-in Postgres above instead of CNPG, which this profile
#    does not run.
step "materialising kratos-secrets from the committed local SOPS bundle"
secrets="$(SOPS_AGE_KEY_FILE=infra/gitops/platform/local/age.key \
  sops -d infra/gitops/platform/local/secrets/platform.enc.yaml |
  yq -o=json '.spec.secretTemplates[] | select(.name == "kratos-secrets") | .stringData')"
[ -n "$secrets" ] || fail "kratos-secrets not found in the local SOPS bundle"
kratos_dsn="postgres://dev:dev@postgres.${NS}.svc.cluster.local:5432/kratos?sslmode=disable"
k -n "$NS" create secret generic kratos-secrets \
  --from-literal=secretsDefault="$(jq -r .secretsDefault <<<"$secrets")" \
  --from-literal=secretsCookie="$(jq -r .secretsCookie <<<"$secrets")" \
  --from-literal=secretsCipher="$(jq -r .secretsCipher <<<"$secrets")" \
  --from-literal=smtpConnectionURI="$(jq -r .smtpConnectionURI <<<"$secrets")" \
  --from-literal=dsn="$kratos_dsn" \
  --dry-run=client -o yaml | k apply -f -

# 6. Kratos + Oathkeeper, wired exactly the way the platform ApplicationSet wires
#    them: the canonical infra/auth/ overlays plus the string artefacts, never
#    inlined into the chart values (lint:auth-inline).
step "installing kratos + oathkeeper"
h dependency build infra/helm/platform/ory >/dev/null
h upgrade --install ory infra/helm/platform/ory \
  -n "$NS" --create-namespace --timeout 8m --wait \
  -f infra/auth/kratos/values.yaml \
  -f infra/auth/oathkeeper/values.yaml \
  -f infra/gitops/platform/local/values.yaml \
  --set-file 'kratos.kratos.identitySchemas.user\.v1\.json=infra/auth/kratos/identity-schemas/user.v1.json' \
  --set-file 'oathkeeper.oathkeeper.accessRules=infra/auth/oathkeeper/access-rules.json'

# 7. The API mock that replaces the application services on `/api` belongs here
#    (ADR-0029), stamping the committed `internal.json` projection into the cluster
#    on every run. Not implemented yet — see the INCOMPLETE note in the header.

# 8. Host edge glue: the catch-all `/` route to the host `next dev` and the
#    docker-bridge EndpointSlice. cluster-ensure.sh skips it on a brand-new cluster
#    (Traefik's CRDs are not registered yet), so stamp it now that they are.
k apply -f infra/local/traefik-config.yaml
bash scripts/cluster-edge-glue.sh

# 9. The committed test identities (ADR-0018) — the same ones the e2e suite uses,
#    not a parallel development-only identity.
bash scripts/identity-seed.sh

# The credentials are committed once, in the e2e fixtures; read them rather than
# repeating them here (bun reads the .ts directly — no Node, no e2e install).
login_email="$(bun --silent -e \
  "console.log((await import('${ROOT}/e2e/fixtures/identities.ts')).USER.email)" 2>/dev/null ||
  echo '<see e2e/fixtures/identities.ts>')"

cat <<EOF

✓ cluster:edge up — real edge + real identity.
  Frontend:      bun run --cwd apps/frontend dev     (host :3000, reached via the edge)
  Open:          https://${DOMAIN}:8443/
  Log in as:     ${login_email}
                 (password: e2e/fixtures/identities.ts — sessions last 7 days)
  Teardown:      mise run cluster:stop  (keep cache) / cluster:delete (delete)

  ⚠ No API mock yet: nothing serves /api on this tier, so any route that fetches
    application data will fail. The auth path is real and complete — logging in,
    CSRF, expiry and the Oathkeeper 401/403 all behave as they do in production.

  This tier is also stateless by design: once the mock lands, a create will not be
  reflected by the next read and no workflow progresses. Persistence, Temporal and
  authorization decisions are exercised against real services (cluster:full).
EOF
