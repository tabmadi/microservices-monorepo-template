#!/usr/bin/env bash
# The API mock, standalone (ADR-0029) — backs `mise run mock:start|stop|logs`.
#
# This is the `edge` profile minus the part you are not exercising: for landing
# pages and other logged-out surfaces there is nothing to authenticate, so the auth
# stack (and the cluster) stays down and the mock runs as a single container on the
# host. Anything behind a session needs the real edge: `mise run cluster:edge`.
#
# Same image and same input as the in-cluster mock (infra/local/mock.yaml): the
# committed `internal.json` projection, mounted read-only. No aggregate, no merge
# step, no fixture files — a mocked response shape that is not derivable from a
# committed OpenAPI artefact is a defect (ADR-0029).
#
# Point the frontend at it with MOCK_API_ORIGIN (see apps/frontend/.env.example):
#   mise run mock:start
#   MOCK_API_ORIGIN=http://127.0.0.1:4010 bun run --cwd apps/frontend dev
set -euo pipefail

source "$(dirname "$0")/lib/log.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONTAINER="platform-api-mock"
IMAGE="stoplight/prism:5.15.10"
PORT="${MOCK_PORT:-4010}"
SPEC="apps/frontend/public/devportal/openapi/internal.json"

start() {
  [ -f "$SPEC" ] || fail "$SPEC is missing — run: mise run gen:openapi-public"
  if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    step "replacing the running mock"
    docker rm --force "$CONTAINER" >/dev/null
  fi

  # Examples-first (ADR-0029): committed `example`/`examples` are served verbatim
  # and only paths without one fall back to schema generation. MOCK_DYNAMIC=1
  # generates every response instead — for an endpoint whose examples do not exist
  # yet, not as a steady state.
  flags=()
  if [ "${MOCK_DYNAMIC:-0}" = "1" ]; then
    flags+=(--dynamic)
  fi

  step "starting the API mock on http://127.0.0.1:${PORT}"
  # Readiness is a docker healthcheck on the LISTENER, not a request to a known
  # path: Prism exposes no health endpoint, and probing a route (`/products`)
  # would couple this script to whichever service happens to own that resource
  # today. `restart unless-stopped` brings the mock back after a Docker or host
  # restart, so a laptop reboot does not silently leave the frontend with no API.
  docker run --detach \
    --name "$CONTAINER" \
    --restart unless-stopped \
    --publish "127.0.0.1:${PORT}:4010" \
    --mount "type=bind,source=${ROOT}/${SPEC},target=/spec/internal.json,readonly" \
    --health-cmd 'nc -z 127.0.0.1 4010' \
    --health-interval 2s \
    --health-timeout 2s \
    --health-retries 15 \
    --health-start-period 3s \
    "$IMAGE" \
    mock --host 0.0.0.0 --port 4010 "${flags[@]}" /spec/internal.json >/dev/null

  step "waiting for the mock to load the projection"
  for _ in $(seq 1 30); do
    status="$(docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' \
      "$CONTAINER")"
    case "$status" in
    healthy)
      ok "API mock ready — the frontend reaches it via MOCK_API_ORIGIN"
      detail "routes it registered: mise run mock:logs"
      return
      ;;
    unhealthy)
      docker logs "$CONTAINER" >&2
      fail "the API mock failed its readiness check"
      ;;
    esac
    sleep 1
  done

  docker logs "$CONTAINER" >&2
  fail "the API mock did not become ready within 30s"
}

case "${1:-}" in
start) start ;;
stop)
  if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    docker rm --force "$CONTAINER" >/dev/null
    ok "API mock stopped"
  else
    ok "API mock is not running"
  fi
  ;;
logs) docker logs --follow "$CONTAINER" ;;
*) fail "usage: $0 {start|stop|logs}" ;;
esac
