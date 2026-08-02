#!/usr/bin/env bash
# Bulk test data for the load suite (ADR-0027).
#
# Why this exists: `GET /api/products` is
# `order by created_at desc limit 100` over an UNINDEXED `created_at`
# (services/catalog/internal/store/queries/products.sql), so every list request
# sorts the entire products table to return its top 100. Against the ~30 rows the
# e2e suite leaves behind that is free and the scenario measures nothing. The
# response size is capped at 100 either way — what seeding grows is the SERVER's
# work per request, which is the part that scales badly.
#
# Why SQL and not the API: creating 5,000 products over HTTP is itself a load
# test, takes minutes, and needs an operator session (catalog gates writes on
# group:operator — ADR-0010). Seeding is setup, not the measurement, so it goes
# straight to the database.
#
#   mise run perf:seed              # 5000 products
#   mise run perf:seed -- 50000     # more
#   mise run perf:seed -- --clean   # remove everything this script created
#
# Every row is named `perf-<n>` so it is identifiable and removable; nothing here
# touches rows this script did not create.
set -euo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)"
source scripts/lib/log.sh

CLUSTER="${CLUSTER:-platform}"
NS="platform"
PREFIX="perf-"

k() { kubectl --context "k3d-${CLUSTER}" -n "$NS" "$@"; }

# The CNPG primary, resolved by label rather than hardcoded: a failover renames
# the pod (postgres-1 → postgres-2) and a hardcoded name silently seeds nothing.
primary="$(k get pods -l 'cnpg.io/instanceRole=primary' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$primary" ]; then
  fail "no CNPG primary found in namespace ${NS} — is the full tier up? (mise run cluster:full)"
fi

# psql over the pod's local socket as the superuser: no port-forward, no
# credential plumbing, and it works identically on every tier.
psql_catalog() { k exec "$primary" -c postgres -- psql -U postgres -d catalog -qtA "$@"; }

count_seeded() { psql_catalog -c "select count(*) from products where name like '${PREFIX}%';"; }

if [ "${1:-}" = "--clean" ]; then
  step "removing seeded products"
  before="$(count_seeded)"
  # Orders reference products by id but carry no FK (services are decoupled at
  # the database — ADR-0000 principle 7), so this delete cannot cascade into
  # another service's data.
  psql_catalog -c "delete from products where name like '${PREFIX}%';" >/dev/null
  ok "removed ${before} seeded product(s)"
  # Orders are NOT removed, and this is deliberate rather than an oversight: a
  # checkout run creates real orders and real Temporal workflow executions
  # (ADR-0027 §Negative), and an order carries no marker distinguishing "created
  # by a load run" from "created by a human". Guessing — by timestamp, or by
  # orphaned product_id — risks deleting real rows, so this script does not.
  # Drop the whole environment instead when order volume matters.
  warn "orders from checkout runs are left in place — they carry no perf marker; recreate the environment if the volume matters"
  exit 0
fi

n="${1:-5000}"
case "$n" in
'' | *[!0-9]*) fail "usage: mise run perf:seed -- [count|--clean] (got '${n}')" ;;
esac

step "seeding ${n} products into catalog (primary: ${primary})"
# One statement, generated server-side: 5,000 round-trips would take minutes,
# generate_series takes well under a second. Prices vary so the rows are not
# byte-identical, which would let Postgres and the JSON encoder behave
# unrealistically well.
psql_catalog -c "
  insert into products (name, price_cents)
  select '${PREFIX}' || g, (g * 37) % 100000
  from generate_series(1, ${n}) as g;
" >/dev/null

total="$(psql_catalog -c 'select count(*) from products;')"
detail "seeded:        $(count_seeded)"
detail "catalog total: ${total}"
ok "catalog seeded — run \`mise run perf:seed -- --clean\` to undo"
