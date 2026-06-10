#!/usr/bin/env bash
# Apply each service's migrations to the local Postgres (ADR-0007).
# Run after `dev:up` (and `skaffold dev` need not be running — this opens its own
# port-forward). Schema migrations are intentionally not run by the chart locally
# (migrations.enabled=false in local-service.yaml).
set -euo pipefail

kubectl -n platform port-forward svc/postgres 5432:5432 >/dev/null 2>&1 &
pf=$!
trap 'kill "$pf" 2>/dev/null || true' EXIT
sleep 2

for dir in services/*/migrations; do
  [[ -d "$dir" ]] || continue

  svc=$(basename "$(dirname "$dir")")
  [[ "$svc" == _template ]] && continue

  echo "→ migrating $svc"
  DATABASE_URL="postgres://dev:dev@localhost:5432/${svc}?sslmode=disable" \
    DBMATE_MIGRATIONS_DIR="$dir" DBMATE_NO_DUMP_SCHEMA=true \
    dbmate up
done

echo "✓ migrations applied"
