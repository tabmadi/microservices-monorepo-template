# Load & performance runbook

How to run a load test, how to read it, and how to record a baseline. The decision
(k6, `perf/`, OTLP into the existing collector) is
[ADR-0027](../adr/0027-load-and-performance-testing.md).

## Model

- **k6** is the only load generator. It is a single static Go binary pinned in
  `perf/.mise.toml`, not the root toolchain — `mise run perf*` installs it on first use.
- Scenarios are JavaScript executed by **k6's own embedded engine**. There is no Node
  here: `perf/` has no `package.json`, no lockfile and no `node_modules`, and adding one
  breaks `mise run lint:node-scope`.
- Runs drive the **edge** (`https://dev.localtest.me:8443/api/…`), so Traefik and the
  Oathkeeper forward-auth hop are inside every measurement.
- Metrics leave k6 over **OTLP into the cluster's OTel collector** and land in Prometheus
  as `k6_*` series, on the same time axis as `k8s_pod_*`. Nothing new ingests them.

## Prerequisites

A running full tier: `mise run cluster:full`. The first `mise run perf*` in a fresh
checkout also needs `mise trust perf/.mise.toml`.

## Run one

```bash
mise run perf:seed          # bulk products, so the read path has a realistic table
mise run perf:smoke         # ~30s — are the scenarios and the target wired?
mise run perf               # the baseline: `load` profile, both scenarios, ~7min
mise run perf:stress        # ramp to saturation; thresholds are EXPECTED to fail
mise run perf:soak          # ~30min sustained, for leak detection
mise run perf:seed -- --clean   # remove the seeded rows
```

`--clean` removes seeded **products** only. A `checkout` run also creates real orders and
real Temporal workflow executions, and those carry no marker separating them from a human's
— roughly 1,700 orders per `stress` run. They are left in place on purpose rather than
guessed at by timestamp; if the accumulated volume starts to matter, recreate the
environment (`mise run cluster:delete && mise run cluster:full`).

Knobs (all optional):

| Variable | Default | Effect |
|---|---|---|
| `PERF_HOST` | `dev.localtest.me:8443` | target edge; the only way to leave localhost |
| `PERF_VUS` | per-profile | override the peak VU count |
| `PERF_OTLP` | `1` | `0` skips the collector forward — results stay in the terminal |
| `PERF_OTLP_PORT` | `14317` | loopback port for the collector forward |

To run one scenario at one profile directly: `bash perf/run.sh checkout stress`.

## The two scenarios

| Scenario | Drives | The ceiling it finds |
|---|---|---|
| `browse` | `GET /api/products`, `GET /api/products/{id}` | edge throughput and the Postgres connection pool — cheap per request, so it saturates those first |
| `checkout` | `POST /api/orders`, polled to a terminal status | Temporal workflow throughput — expensive per request |

## Reading the result

Two places, and you need both:

1. **The terminal summary.** Thresholds set the exit code, so this is the pass/fail. A
   threshold breach on a nightly `load` run is a performance regression to triage.
2. **The `Load test` dashboard** (Grafana, uid `load-test`). Generator-side throughput and
   latency over pod CPU, memory and limit-utilisation for the same window. This is where a
   number becomes a diagnosis.

### What the shapes mean

- **Throughput flattens while VUs keep climbing** — you found the knee. Whatever is
  saturated is saturated at that request rate; the panels in the bottom row say what.
- **p99 pulls away from p50 while throughput is flat** — queueing. This is what saturation
  looks like *before* it looks like errors, and it is the earliest honest signal.
- **`checkout_settle` p95 climbs while `create_order` latency stays flat** — the
  characteristic async failure. The API is happily accepting work faster than the Temporal
  workers retire it. Confirm on `temporal schedule→start p95` in the bottom row.
- **Latency climbs while pod CPU stays flat** — not CPU-bound. Look at the connection pool
  (`postgres` backends) and lock contention, not at replica count.
- **Memory climbs through a soak and does not come back down** — a leak. Compare against
  `Memory headroom against limit`: the OOM kill happens at 1.0.
- **The edge outranks the service on CPU** — expected on the read path, and the reason
  `browse` drives the edge rather than a port-forwarded pod. Measured on the local tier at
  ~128 req/s: Oathkeeper ~190 mc and Traefik ~185 mc against catalog's ~120 mc, i.e. the
  ingress + forward-auth hop costs roughly 3× the business logic it protects. If you are
  sizing anything from a read-heavy workload, size the edge first.

### Two traps

- **`Dropped iterations` > 0 means the numbers are wrong.** k6 could not start iterations
  on time, so the generator — not the platform — is the bottleneck, and everything on the
  dashboard is an understatement. Take the `k6-operator` swap
  ([operational surface](../operational-surface.md)) before believing a run that shows this.
- **`checkout_settle` cannot resolve below the poll interval** (1s, `POLL_INTERVAL_S` in
  `perf/scenarios/checkout.js`). A p95 of ~1.0s on an idle cluster means "faster than we
  can measure", not "one second". The metric earns its resolution under load, where real
  settle time is well above the interval.

### `stress` measures concurrency, not maximum throughput

Every scenario includes think time (`sleep` between requests), which is what makes a VU
behave like a user rather than a tight loop. The side effect is that **each VU is capped at
roughly one request per second**, so the `stress` profile's request rate is a function of
its VU count, not of what the platform can absorb. Measured on the local tier: 20 VUs → 17
req/s, 140 VUs → 115 req/s, latency flat at p95 ≈ 5ms throughout. That is a straight line,
not a knee — the generator is pacing itself, and the platform was never the constraint.

To hunt for the actual ceiling, raise `PERF_VUS` well past the profile default until either
latency bends or `Dropped iterations` goes non-zero (at which point see the trap above, and
take the k6-operator swap). Removing think time is the other lever, but do it in a separate
scenario rather than by editing these — the baseline's comparability depends on its shape
staying fixed.

### Seeding changes the server's work, not the response

`GET /api/products` is `order by created_at desc limit 100` over an **unindexed**
`created_at`, so the response is capped at 100 rows however many products exist — but every
request sorts the whole table to find them. Seeding therefore does not grow the payload; it
grows the per-request server cost, which is the part that degrades with scale. Two
consequences: `catalog_page_size` saturates at 100 and is not a table-size readout, and any
latency number for this endpoint is meaningless without the seeded row count beside it.

## Local numbers are not capacity numbers

The generator runs on the same host as the k3d node and competes with it for CPU, and one
k3d node is not a production topology. **Saturation shapes transfer; absolute ceilings do
not.** Treat a local run as a relative regression signal against the previous baseline. For
absolute figures, take the `k6-operator` Scale swap and generate load inside the cluster.

## Record a baseline

After a `mise run perf` on a quiet machine, record in the PR that changes performance:

- the `load` profile's p95 per endpoint and the checkout settle p95,
- peak pod memory and CPU for the services under test,
- the catalog row count (`mise run perf:seed` size) — a latency number without it is
  meaningless.

Compare like for like: same profile, same seed size, same tier.

### The Prometheus side of a baseline is not durable

Prometheus's TSDB is an `emptyDir` on the local tier (the ADR-0011 POC floor), so **any
rollout of the observability chart destroys all metric history** — `mise run
platform:deploy -- observability` and a `cluster:delete` both wipe it, silently and
instantly. A resource or capacity comparison that depends on querying "before" numbers out
of Prometheus will therefore fail exactly when you redeploy to apply the change you are
measuring.

The `perf/results/*.json` summaries are files and survive, which is why they are the
authoritative record. Copy them somewhere before a redeploy, and write the pod-level peaks
into the PR (or the values comment) rather than assuming you can re-query them.

### Interpreting a small delta

At the load profile this platform serves single-digit-millisecond latencies, so a *relative*
percentage is misleading: p95 varied between **4.40ms and 5.69ms across ~15 identical runs**
in one sitting, a ±13% spread from noise alone. Two rules follow:

- Judge a latency change by its ABSOLUTE size first. Sub-millisecond movement at 5ms is
  noise however large the percentage looks.
- A freshly rolled cluster is slower for the first minutes: Postgres restarts with a cold
  buffer cache, and Loki/Tempo/the collectors re-ingest at once. Let it settle, or take two
  samples, before believing a regression.

## Cadence

| Suite | When |
|---|---|
| `perf:smoke` | per-PR, label-gated, alongside `e2e:smoke` |
| `perf` (`load`) | nightly + pre-release |
| `perf:stress` | on demand, before a sizing or HPA decision ([ADR-0020](../adr/0020-resource-management.md)) |

Performance suites are **not** part of `mise run test`, `check`, or `ci:affected`, and
never implicitly gate a merge.
