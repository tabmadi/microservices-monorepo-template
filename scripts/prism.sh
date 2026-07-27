#!/usr/bin/env bash
# Join the canonical service contracts at runtime, then run one stateless Prism
# API. Both tools stay in Docker and nothing is shipped in the browser bundle.
set -euo pipefail

source "$(dirname "$0")/lib/log.sh"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONTAINER="platform-prism"
IMAGE="stoplight/prism:5.15.10"
REDOCLY_IMAGE="redocly/cli:2.40.0"
RUNTIME_DIR="${ROOT}/.runtime/prism"
CONTRACT="${RUNTIME_DIR}/openapi.yaml"
NEXT_CONTRACT="${RUNTIME_DIR}/openapi.next.yaml"

aggregate() {
  shopt -s nullglob
  specs=("${ROOT}"/services/*/openapi.yaml)
  if [[ ${#specs[@]} -eq 0 ]]; then
    fail "no canonical OpenAPI documents found under services/*/openapi.yaml"
  fi

  step "discovered ${#specs[@]} canonical OpenAPI documents"
  for spec in "${specs[@]}"; do
    detail "${spec#"${ROOT}/"}"
  done

  step "validating canonical OpenAPI documents"
  vacuum lint --ruleset "${ROOT}/tools/codegen/openapi-ruleset.yaml" \
    --fail-severity error "${specs[@]}"

  step "building runtime-only Prism aggregate"
  mkdir -p "$RUNTIME_DIR"
  if [[ -e "$NEXT_CONTRACT" ]]; then
    unlink "$NEXT_CONTRACT"
  fi
  container_specs=()
  for spec in "${specs[@]}"; do
    container_specs+=("/contracts/${spec#"${ROOT}/services/"}")
  done
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=${ROOT}/services,target=/contracts,readonly" \
    --mount "type=bind,source=${RUNTIME_DIR},target=/runtime" \
    "$REDOCLY_IMAGE" \
    join "${container_specs[@]}" --output /runtime/openapi.next.yaml
  yq -i \
    '.info = {
      "title": "Local Development Prism Aggregate",
      "version": "runtime",
      "description": "Runtime-only aggregate of canonical service contracts for local Prism mocking."
    } |
      .servers = [{"url": "/api"}]' \
    "$NEXT_CONTRACT"

  step "validating runtime Prism aggregate"
  vacuum lint --ruleset "${ROOT}/tools/codegen/openapi-ruleset.yaml" \
    --fail-severity error "$NEXT_CONTRACT"
  mv "$NEXT_CONTRACT" "$CONTRACT"
  ok "runtime aggregate is valid"
}

start() {
  if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    step "stopping existing Prism container before rebuilding its contract"
    docker rm --force "$CONTAINER" >/dev/null
  fi

  aggregate

  step "starting unified Prism API at http://localhost:4010"
  docker run --detach \
    --name "$CONTAINER" \
    --restart unless-stopped \
    --publish 127.0.0.1:4010:4010 \
    --mount "type=bind,source=${ROOT}/services,target=/contracts/services,readonly" \
    --mount "type=bind,source=${CONTRACT},target=/runtime/openapi.yaml,readonly" \
    --health-cmd 'nc -z 127.0.0.1 4010' \
    --health-interval 2s \
    --health-timeout 2s \
    --health-retries 15 \
    --health-start-period 3s \
    "$IMAGE" \
    mock --host 0.0.0.0 --port 4010 --dynamic --multiprocess=false \
    --verboseLevel info \
    /runtime/openapi.yaml >/dev/null

  step "waiting for Prism to load the runtime aggregate"
  for _ in {1..30}; do
    status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' "$CONTAINER")
    case "$status" in
    healthy)
      ok "unified Prism API is ready at http://localhost:4010"
      return
      ;;
    unhealthy)
      docker logs "$CONTAINER" >&2
      fail "Prism failed its readiness check"
      ;;
    esac
    sleep 1
  done

  docker logs "$CONTAINER" >&2
  fail "Prism did not become ready within 30 seconds"
}

case "${1:-}" in
start)
  start
  ;;
validate)
  aggregate
  ;;
stop)
  if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    step "stopping Prism"
    docker rm --force "$CONTAINER" >/dev/null
    ok "Prism stopped"
  else
    ok "Prism is not running"
  fi
  ;;
logs)
  docker logs --follow "$CONTAINER"
  ;;
*)
  fail "usage: $0 {start|stop|logs|validate}"
  ;;
esac
