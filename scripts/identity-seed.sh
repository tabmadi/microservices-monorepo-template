#!/usr/bin/env bash
# Seed the committed deterministic test identities into Kratos (ADR-0018, ADR-0029).
#
# The `edge` profile logs in for real, so it needs a real identity — and it consumes
# the one the e2e suite already defines rather than inventing a development-only
# one. e2e/fixtures/identities.ts is the single source of the credentials; this
# reads them with bun (which runs the .ts directly, so no Node and no `e2e:install`)
# and provisions them through the Kratos admin API, exactly as
# e2e/fixtures/bootstrap.ts does.
#
# Two deliberate differences from the e2e bootstrap:
#   • idempotent, not reset-per-run — a human's enrolled second factor and live
#     session survive re-running the profile;
#   • no OpenFGA tuple: the `edge` profile runs no OpenFGA and no ops tier, and the
#     coarse ops gate is the `operator` trait, which is set here.
#
# Requires Kratos up. Run by scripts/cluster-edge-profile.sh; safe to run alone.
set -euo pipefail

source "$(dirname "$0")/lib/log.sh"

CLUSTER="${CLUSTER:-platform}"
NS="platform"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
k() { kubectl --context "k3d-${CLUSTER}" -n "$NS" "$@"; }

identities="$(bun --silent -e \
  'console.log(JSON.stringify((await import("./e2e/fixtures/identities.ts")).IDENTITIES))')"

step "seeding the committed test identities into Kratos"
k port-forward svc/ory-kratos-admin 4434:80 >/dev/null &
pf=$!
trap 'kill "$pf" 2>/dev/null || true' EXIT
sleep 3
admin="http://localhost:4434"

for i in $(seq 0 "$(($(jq length <<<"$identities") - 1))"); do
  id="$(jq -c ".[$i]" <<<"$identities")"
  email="$(jq -r .email <<<"$id")"
  existing="$(curl -fsS \
    "${admin}/admin/identities?credentials_identifier=$(jq -rn --arg e "$email" '$e|@uri')" |
    jq -r --arg e "$email" 'map(select(.traits.email == $e)) | .[0].id // empty')"
  if [ -n "$existing" ]; then
    detail "${email} already exists (${existing})"
    continue
  fi
  # Import path: Kratos hashes the password and does NOT run it through the sign-up
  # policy (HIBP/length), so committed deterministic credentials are fine. The
  # address is pre-verified so login never waits on the (unwired) SMTP sink. The
  # `operator` trait is the coarse ops-tier claim (ADR-0017) and is always enforced.
  body="$(jq -n --argjson i "$id" '{
    schema_id: "user_v1",
    traits: { email: $i.email, operator: $i.operator },
    credentials: { password: { config: { password: $i.password } } },
    verifiable_addresses: [{ value: $i.email, via: "email", verified: true, status: "completed" }]
  }')"
  created="$(curl -fsS -H 'Content-Type: application/json' -X POST "${admin}/admin/identities" -d "$body" |
    jq -r .id)"
  detail "created ${email} (${created})"
done

ok "test identities present (credentials: e2e/fixtures/identities.ts)"
