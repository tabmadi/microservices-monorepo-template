#!/usr/bin/env bash
# k6 runner (ADR-0027): wires a scenario to the cluster's telemetry plane, then runs it.
#
#   perf/run.sh <scenario> [profile]
#   perf/run.sh browse load
#
# Two things this handles that a bare `k6 run` cannot:
#
#  1. THE OTLP PATH. ADR-0011's invariant is that metrics reach Prometheus only as
#     an OTLP push through the collector — Prometheus has no scrape config and no
#     remote-write receiver. The collector is cluster-internal (ClusterIP), so a
#     host-side k6 reaches it through a short-lived port-forward, exactly as the
#     e2e suite reaches Tempo/Loki/Prometheus (e2e/fixtures/observability.ts).
#     The forward must outlive k6's final flush, hence the trap rather than a
#     backgrounded one-liner.
#
#  2. THE PROXY HOLE. The local edge (*.localtest.me) must be hit directly. A dev
#     with HTTPS_PROXY set otherwise sends every VU's request through their proxy
#     and measures that instead — same reason e2e/.mise.toml sets NO_PROXY.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"
source ../scripts/lib/log.sh

scenario="${1:-}"
profile="${2:-smoke}"
[ -n "$scenario" ] || fail "usage: perf/run.sh <scenario> [profile]"

script="scenarios/${scenario}.js"
[ -f "$script" ] || fail "no such scenario: ${script}"

CLUSTER="${CLUSTER:-platform}"
# Loopback port for the collector forward. High and specific so it does not
# collide with the e2e suite's forwards (13100/13200/19090) if both are running.
OTLP_PORT="${PERF_OTLP_PORT:-14317}"

k6_args=(run "$script")

# Anonymous usage reporting off, matching the phone-home posture already applied
# to Temporal and MinIO in this repo.
k6_args+=(--no-usage-report)

# Machine-readable summary alongside the human one. This is what a baseline is
# recorded from and what CI uploads as an artifact — the Prometheus series expire
# with the TSDB retention (15d), so a run whose numbers matter needs a file.
# Gitignored: results are evidence for a PR, not repo content.
mkdir -p results
k6_args+=(--summary-export "results/${scenario}-${profile}.json")

if [ "${PERF_OTLP:-1}" = "1" ]; then
  step "forwarding otel-collector :${OTLP_PORT} → svc/otel-collector:4317"
  kubectl --context "k3d-${CLUSTER}" -n platform port-forward svc/otel-collector "${OTLP_PORT}:4317" >/dev/null 2>&1 &
  pf=$!
  trap 'kill "$pf" 2>/dev/null || true' EXIT
  # Wait for the forward rather than sleeping a guessed constant: a forward that
  # is not up yet makes k6 drop the whole run's metrics and say nothing about it.
  for _ in $(seq 1 40); do
    if (echo >"/dev/tcp/127.0.0.1/${OTLP_PORT}") 2>/dev/null; then break; fi
    sleep 0.25
  done
  if ! (echo >"/dev/tcp/127.0.0.1/${OTLP_PORT}") 2>/dev/null; then
    fail "otel-collector port-forward did not come up — is the full tier running? (PERF_OTLP=0 to run without metrics export)"
  fi

  export K6_OTEL_GRPC_EXPORTER_ENDPOINT="127.0.0.1:${OTLP_PORT}"
  export K6_OTEL_GRPC_EXPORTER_INSECURE="true"
  # service.name is promoted to a Prometheus label by the collector's OTLP
  # translation (infra/helm/platform/observability/templates/prometheus.yaml), so
  # this is the label every k6 series is grouped by — and the one thing keeping
  # load metrics from being mistaken for a platform service's own.
  export K6_OTEL_SERVICE_NAME="k6"
  # Namespace k6's built-ins. Without this they export as bare `http_req_duration`,
  # `http_reqs`, `checks`, `vus` — generic names squatting the global metric
  # namespace of a Prometheus that every service shares, and confusingly adjacent
  # to the platform's own `http_server_request_duration_seconds` from ADR-0011.
  # The prefix applies to the scenarios' custom metrics too, which is why those
  # are named bare (`checkout_settle`, not `perf_checkout_settle`) — they arrive
  # as `k6_checkout_settle_milliseconds`. Everything from a load run is therefore
  # `k6_*` in Prometheus, and nothing else is.
  export K6_OTEL_METRIC_PREFIX="k6_"
  # Export often. The default interval is longer than a smoke run, which would
  # end with the run's metrics still sitting in the exporter's buffer.
  export K6_OTEL_EXPORT_INTERVAL="5s"
  export K6_OTEL_FLUSH_INTERVAL="1s"
  k6_args+=(--out opentelemetry)
else
  warn "PERF_OTLP=0 — metrics stay local to this terminal, nothing reaches Grafana"
fi

export PERF_PROFILE="$profile"
step "k6 ${scenario} @ profile=${profile} → ${PERF_HOST:-dev.localtest.me:8443}"

# The Load test dashboard is deliberately NOT linked from the Overview landing page
# (ADR-0026 reserves that for incident triage; a load run is a planned experiment).
# This line is therefore its primary entry point — printed BEFORE the run so it can
# be opened and watched live, with from/to bracketing exactly this run.
started_ms="$(($(date +%s) * 1000))"
if [ "${PERF_OTLP:-1}" = "1" ]; then
  host="${PERF_GRAFANA_HOST:-grafana.ops.${PERF_HOST:-dev.localtest.me:8443}}"
  detail "watch it: https://${host}/d/load-test/load-test?var-scenario=${scenario}&from=${started_ms}&to=now"
fi

# `|| k6_status=$?` rather than a bare call: k6 exits non-zero when a threshold is
# breached, and under `set -e` a bare call would abort the script right here — losing
# the closing link on exactly the runs where you most want to go look at the graphs.
k6_status=0
k6 "${k6_args[@]}" || k6_status=$?

# Reprint on the way out with the window closed, so a finished run leaves behind a
# link to exactly its own time range rather than a drifting `to=now`.
if [ "${PERF_OTLP:-1}" = "1" ]; then
  detail "this run: https://${host}/d/load-test/load-test?var-scenario=${scenario}&from=${started_ms}&to=$(($(date +%s) * 1000))"
fi
exit "$k6_status"
