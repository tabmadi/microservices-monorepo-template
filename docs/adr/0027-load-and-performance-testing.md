# ADR-0027: Load & Performance Testing

- **Status:** Accepted
- **Date:** 2026-07-26
- **Deciders:** Platform team
- **Related:** [ADR-0011](0011-observability.md), [ADR-0016](0016-environment-parity.md), [ADR-0018](0018-testing-strategy.md), [ADR-0020](0020-resource-management.md), [ADR-0025](0025-service-map-apm-ui.md), [ADR-0026](0026-dashboard-hierarchy.md)

## Context

[ADR-0018](0018-testing-strategy.md) pins the whole correctness pyramid — unit, service
integration, preflight, browser acceptance, visual — and ends at a binary verdict: the
platform works, or it does not. Nothing in it asks **how much it costs to work, or at what
point it stops working.** Every suite runs at a load of approximately one user.

Three accepted decisions already depend on an answer we do not have:

- [ADR-0020](0020-resource-management.md) requires every container to declare CPU/memory
  requests and a memory limit, and makes HPA "opt-in per service on a documented
  sustained-load signal." Both rules are `(review-only)` because there is no instrument
  that produces the number. Requests are currently set by judgement.
- [ADR-0011](0011-observability.md) and [ADR-0026](0026-dashboard-hierarchy.md) built the
  apparatus to *observe* saturation — the `kubeletstats` CPU/memory series, the capacity
  row on Overview, the `ClusterCPURequestsCommitted` / `NodeMemoryPressure` alerts. That
  apparatus has never been shown to fire, because nothing has ever pushed the platform
  hard enough to make it fire.
- [ADR-0000](0000-platform-foundations.md)'s thesis is that **per-service cost dominates**
  at ~100 services. That claim is quantitative and currently unmeasured. A measurement
  taken during the e2e suite (2026-07-26, `cluster:full`, one node) makes the point: the
  node peaked at **7.3 GiB and under 1 core of pod CPU**, of which the observability stack
  alone (Loki, Tempo, Alloy, two collectors) was ~1.3 GiB, and **not one business service
  appeared in the top twelve consumers on either axis.** At approximately one user, the
  template is entirely platform cost. Whether that stays true at 100× the traffic is the
  question this ADR buys the ability to ask.

So this ADR adds the missing layer: a **deliberate, repeatable load experiment** whose
results are read through the observability stack we already run. It does not change the
correctness pyramid; it sits beside it.

## Decision drivers

In priority order:

1. **No new always-on component.** The Core floor is budgeted
   ([`docs/operational-surface.md`](../operational-surface.md)). A load generator is used
   for minutes per week; anything that must run continuously to serve it fails the budget
   rule outright.
2. **Results land in the stack we already operate.** A load tool with its own private
   metrics store, dashboards and query language is a second observability plane
   ([ADR-0011](0011-observability.md) picked one). Load numbers must sit on the same
   Grafana time axis as `k8s_pod_memory_working_set_bytes`, or correlating "the p99 rose"
   with "that pod hit its limit" is manual work every single time.
3. **No new runtime.** [ADR-0001](0001-language-and-runtime.md) is Go + Bun, with Node
   sanctioned as a hard-scoped island for the Playwright runner
   ([ADR-0018](0018-testing-strategy.md)). A load tool that drags in Python or a JVM adds
   a third toolchain for one job.
4. **Tests are files in this repo** ([ADR-0000](0000-platform-foundations.md) principle 3),
   reviewed and diffable — not a recorded session or a UI-authored plan.
5. **Local–prod parity** ([ADR-0016](0016-environment-parity.md)). The same scenario file
   runs against `cluster:full` on a laptop and against a deployed environment, changing
   only a target URL.

## Considered options

- **k6 (Grafana)** — *chosen.* Single static Go binary, so it is a `mise` tool pin and
  nothing else; scenarios are plain JavaScript executed by k6's own embedded engine
  (Sobek), so **it adds no Node and no npm** — the JS here is a configuration dialect, not
  a runtime commitment. Ships a built-in OpenTelemetry metrics output (`-o opentelemetry`,
  no longer behind an `experimental-` prefix in the pinned v2.1.0), which means load
  metrics reach Prometheus through the *existing* OTel collector with no new ingest path.
  Thresholds are
  declared in the scenario and set the process exit code, so a run is a CI gate without a
  wrapper.
- **Locust** — good distributed model and the scenario-as-code property, but it is Python:
  a third language toolchain, a `pip` dependency tree, and a container image to maintain,
  for a tool used minutes per week. Its metrics are also its own; reaching Prometheus means
  an exporter sidecar. Rejected on drivers 1 and 3.
- **Gatling** — the strongest reporting of the field and genuinely high throughput per
  load node, but it is a JVM toolchain (Scala/Java DSL) and its HTML report is a parallel,
  offline results plane rather than a feed into Grafana. Rejected on drivers 2 and 3.
- **JMeter** — mature and ubiquitous, but its test plan is a large XML artefact that is
  authored in a GUI and reviews as a blob. Directly against driver 4, plus the JVM cost.
- **Vegeta** — Go, tiny, and a natural fit for driver 3, but it is a constant-rate hitter
  of a URL list. The scenario that matters here is multi-step and stateful (create an
  order, then poll it to a terminal status), which Vegeta models only by shelling around
  it. Rejected: too thin for the saga path, which is the interesting path.
- **Writing our own in Go** — tempting given driver 3, and rejected under
  [ADR-0000](0000-platform-foundations.md) principle 9. We would be reimplementing VU
  scheduling, ramping executors, percentile aggregation and threshold evaluation, all of
  which k6 already does, to avoid a single pinned binary.

## Decision

### Load testing is a fourth concern, not a fifth pyramid layer

The pyramid in [ADR-0018](0018-testing-strategy.md) answers *is it correct*. This answers
*what does it cost and where does it break*. They are different questions with different
cadences and different failure meanings — a red load run means "slower than the budget",
not "broken" — so **performance tests are not part of `mise run test`, `ci:affected`, or
the e2e suites**, and never gate a merge implicitly.

| Concern | Tool | Environment | Verdict it gives |
|---------|------|-------------|------------------|
| Correctness (all layers) | see [ADR-0018](0018-testing-strategy.md) | up to `cluster:full` | works / broken |
| **Load & performance** | **k6** | `cluster:full` | within budget / regressed / saturated |

### The tool

**k6 is the only load-generation tool.** It is pinned in `perf/.mise.toml` as an island
tool — the same containment idiom [ADR-0018](0018-testing-strategy.md) uses for the
Playwright Node pin and [ADR-0001](0001-language-and-runtime.md) uses for Ansible — so a
developer running `lint` or `test` never installs it. Root tasks `perf`, `perf:smoke`,
`perf:stress` and `perf:seed` delegate into it with `mise run -C perf …`.

k6's scenario language is JavaScript on its own embedded engine. **This does not extend the
Node escape hatch**: no `package.json`, no lockfile, no `node_modules`, no Node binary.
`scripts/lint-node-scope.sh` continues to assert npm exists only in `e2e/`, and `perf/`
must never acquire any of those files.

### Layout

All performance tests live in a single repo-root **`perf/`** workspace:

- `perf/lib/` — shared configuration, target resolution, thresholds, and response checks.
- `perf/scenarios/` — one file per load shape. Each is a runnable k6 script.
- `perf/seed/` — bulk data provisioning, so a read path is measured against a realistic
  table rather than an empty one.

### The scenarios

Two paths are load-bearing and are the committed floor. Both are driven **through the
edge** (Traefik → Oathkeeper → service), not against a port-forwarded pod, because the
edge is part of the system under test and [ADR-0009](0009-api-gateway.md) puts a
forward-auth hop on every request:

| Scenario | Path | What it stresses |
|----------|------|------------------|
| `browse` | `GET /api/products`, `GET /api/products/{id}` | read path: edge → catalog → Postgres. Cheap per request, so it finds the *edge and connection-pool* ceiling. |
| `checkout` | `POST /api/orders` then poll to terminal status | write path: edge → orders → Temporal saga → catalog + payment. Expensive per request, so it finds the *workflow throughput* ceiling. |

Each scenario exposes four profiles selected by `PROFILE`: **`smoke`** (1 VU, seconds —
proves the script and the target are wired, cheap enough for CI), **`load`** (the steady
baseline, the number regressions are measured against), **`stress`** (ramp past the knee
until thresholds break), and **`soak`** (sustained, for leak detection). Profiles are
data, not copy-pasted scenario files.

### Results land in Prometheus, via the collector

k6 runs with `--out opentelemetry`, exporting to the existing OTel collector. This is the
same invariant [ADR-0011](0011-observability.md) states for everything else — **the only
way metrics reach Prometheus is an OTLP push through the collector** — and it means a load
run needs no new ingest path, no Prometheus remote-write receiver, and no scrape config.
Everything a run emits is namespaced `k6_*` (`K6_OTEL_METRIC_PREFIX`) and carries
`service_name="k6"`, so load series are queryable next to `k8s_pod_cpu_usage` on one time
axis without colliding with, or being mistaken for, a service's own telemetry. k6's default
system tags are **not** exported wholesale: `url`, `name` and `error` are unbounded by
construction (a URL label mints one series per product id) and are dropped in favour of a
hand-written `endpoint` route-template tag, per [ADR-0011](0011-observability.md)'s
prohibition on high-cardinality labels.

k6's anonymous usage reporting is disabled (`--no-usage-report`), consistent with the
phone-home posture already applied to Temporal and MinIO.

A dedicated **`load-test` dashboard** correlates the two planes: k6-side throughput,
latency percentiles and error rate, over pod CPU/memory and limit-utilisation for the
services under test. It sits **outside the L1–L3 triage funnel** of
[ADR-0026](0026-dashboard-hierarchy.md) by design — that funnel exists to diagnose an
unplanned incident, whereas a load test is a planned experiment where the operator already
knows what they are looking at. It is reached from the `perf` task output, not from
Overview.

### Where the load comes from

The default runner is **k6 on the developer's or CI machine, hitting the edge**. It adds
nothing to the cluster. The consequence is honest and must be stated when reading results:
the generator competes for the same host CPU as the k3d node, so **local numbers are a
regression signal and a saturation-shape signal, not an absolute capacity figure.**

The **Scale swap is `k6-operator`** — k6 as a CRD generating load from inside the cluster,
across multiple pods. Its trigger: *the load generator itself becomes the bottleneck (k6
`dropped_iterations` > 0 at the target rate), or a scenario needs more throughput than one
machine sustains.* Until then the floor is the binary, per the budget rule in
[`docs/operational-surface.md`](../operational-surface.md).

### Cadence and gating

| Suite | Trigger | Purpose |
|-------|---------|---------|
| `perf:smoke` | per-PR, label-gated (alongside `e2e:smoke`) | the scenarios still run; ~30s |
| `perf` (`load`) | nightly + pre-release | the baseline number, tracked over time |
| `perf:stress` | on demand, before a capacity decision | find the knee; produce the ADR-0020 sizing/HPA signal |

Thresholds live in the scenario files and are **budgets, not SLOs** — deliberately looser
than the [ADR-0011](0011-observability.md) service SLOs, because a load run deliberately
pushes into territory where the SLO is expected to be violated. A threshold breach fails
the run; a *nightly* threshold breach is a performance regression to triage, not a
rollback trigger.

## Consequences

### Positive

- [ADR-0020](0020-resource-management.md)'s requests, limits and HPA triggers stop being
  judgement calls: there is an instrument that produces the number.
- The capacity alerts and the Overview capacity row become testable — a stress run is how
  we prove they fire before an incident proves it for us.
- No new always-on component, no new runtime, no second metrics plane. The additions are
  one pinned binary and a directory of text files.
- The template ships an answer to "how much does this platform cost to run", which is the
  question its own thesis rests on.

### Negative / Risks

- **Local numbers are not capacity numbers.** The generator shares a host with the
  cluster. Mitigated by stating it everywhere results are reported, by treating the
  baseline as a *relative* series, and by the k6-operator swap when absolute figures are
  needed.
- **A single k3d node is not a production topology.** Saturation shapes transfer; absolute
  ceilings do not. Accepted — the same caveat [ADR-0016](0016-environment-parity.md)
  already carries for the local tier.
- **Scenario rot.** A scenario driving `/api/orders` breaks when that contract changes,
  and unlike e2e it is not on the per-PR path to catch it early. Mitigated by the
  label-gated `perf:smoke` and by the nightly run.
- **JavaScript reappears outside the sanctioned island.** Mitigated by the hard boundary
  above (no Node, no npm, no lockfile) and by keeping `perf/` out of the Bun workspace;
  the node-scope lint continues to enforce that npm lives only in `e2e/`.
- **Load tests generate real data.** A checkout run creates real orders and Temporal
  workflow executions in whatever environment it targets. `perf/` therefore refuses to run
  against a target it was not explicitly pointed at, and seeded data is namespaced by a
  recognisable prefix so it can be identified and removed.

### Follow-ups

- `perf/` workspace: `.mise.toml` (k6 pin + tasks), `lib/`, `scenarios/browse.js`,
  `scenarios/checkout.js`, `seed/`.
- Root delegate tasks `perf`, `perf:smoke`, `perf:stress`, `perf:seed`.
- `infra/observability/dashboards/load-test.json` + its `kustomization.yaml` line.
- `docs/perf/runbook.md` — how to run one, how to read it, how to record a baseline.
- k6-operator recorded as a Scale swap in [`docs/operational-surface.md`](../operational-surface.md).
- A nightly CI job and the label-gated smoke lane in `.github/workflows/`.

## Rules

- k6 is the only load-generation tool. Locust, Gatling, JMeter, Vegeta, and hand-rolled load generators are not used. `(review-only)`
- All performance tests live in the repo-root `perf/` workspace; scenarios are committed JavaScript files, never a GUI-authored or recorded plan. `(review-only)`
- `perf/` contains no `package.json`, no npm lockfile, and no `node_modules`: k6 runs its own embedded JS engine and does not extend the Node escape hatch of [ADR-0018](0018-testing-strategy.md). `(CI: lint:node-scope)`
- The k6 binary is pinned in `perf/.mise.toml`, never in the root `[tools]`; root `perf*` tasks delegate with `mise run -C perf …`. `(review-only)`
- Load-test metrics reach Prometheus as an OTLP push through the OTel collector (`--out opentelemetry`), like every other metric ([ADR-0011](0011-observability.md)). A load tool's private metrics store, exporter sidecar, or Prometheus remote-write receiver is not introduced. `(review-only)`
- Load-run series are namespaced `k6_*` and carry `service_name="k6"`. k6's `url`, `name` and `error` system tags are not exported; a request's identity is a bounded `endpoint` route-template tag ([ADR-0011](0011-observability.md) cardinality rule). `(review-only)`
- k6 runs with `--no-usage-report`; phone-home telemetry stays off. `(review-only)`
- Every scenario declares thresholds; the run's exit code is the verdict. A scenario without thresholds is a defect. `(review-only)`
- Load shapes are `PROFILE`-selected data (`smoke`/`load`/`stress`/`soak`), not duplicated scenario files. `(review-only)`
- Scenarios drive the edge (`https://<host>/api/…`), not port-forwarded pods, so the gateway and forward-auth hop are inside the measurement. `(review-only)`
- Performance suites are not part of `mise run test`, `ci:affected`, or the e2e suites, and never implicitly gate a merge. `(review-only)`
- Results from a co-hosted generator are reported as relative regression signals, never as absolute capacity figures. Absolute figures require the k6-operator Scale swap. `(review-only)`
- Load generated against a shared environment requires an explicit target; `perf/` never defaults to anything but the local edge. `(review-only)`
