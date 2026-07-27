# ADR-0020: Resource Management & Scheduling

- **Status:** Accepted
- **Date:** 2026-07-26
- **Deciders:** Platform team
- **Related:** [ADR-0000](0000-platform-foundations.md), [ADR-0003](0003-cluster-topology.md), [ADR-0006](0006-temporal.md), [ADR-0011](0011-observability.md), [ADR-0027](0027-load-and-performance-testing.md)

## Context

Application services, stateful platform components, and batch/bootstrap Jobs all share the three-node set
([ADR-0003](0003-cluster-topology.md)). Without resource governance a single noisy service can starve
Temporal, Postgres, or the observability stack, and the scheduler has no basis for eviction order. At the
target scale a small team cannot babysit per-pod tuning, so the policy must be defaulted, not per-service.

## Decision drivers

1. **No workload can starve a Core component** ([docs/operational-surface.md](../operational-surface.md)).
2. **Defaults over per-service tuning** — the policy applies to every namespace without per-service work.
3. **Predictable eviction order** under pressure.
4. **Boring, in-tree Kubernetes primitives** ([ADR-0003](0003-cluster-topology.md)).

## Decision

Every container declares resources, and each namespace carries guardrails.

- **Requests and limits are mandatory.** Every container sets CPU/memory requests and memory limits. CPU
  limits are set only where throttling is desired; CPU requests plus priority handle contention. A
  container with no requests is a defect. The asymmetry is deliberate and now measured: memory is
  incompressible, so a limit is the only thing standing between one leak and a node-wide OOM, whereas a CPU
  limit throttles via CFS and turns a burst into tail latency. `temporal-history` bursts to **2.1 cores**
  from near-idle; a plausible-looking 500m limit would have quartered it and shown up only as slow
  checkouts. Contention is handled by requests plus the priority tiers below.
- **`LimitRange` per namespace** supplies default requests/limits so a missing value fails safe rather
  than scheduling unbounded.
- **`ResourceQuota` per namespace** caps aggregate CPU/memory so one namespace cannot consume the cluster.
- **`PriorityClass` tiers** set eviction order: `platform-critical` (CNPG, Temporal, OpenFGA, Kratos,
  Oathkeeper, edge, observability) > `product` (application services) > `batch` (bootstrap/one-shot Jobs).
  Under pressure, batch dies first, Core last.
- **`PodDisruptionBudget`** for every multi-replica and stateful component, so voluntary disruptions
  (drains, upgrades) never take quorum below one.
- **No HPA by default.** Autoscaling is opt-in per service when a measured, sustained load signal justifies
  it — the same "grow on a trigger, not a guess" discipline as [ADR-0003](0003-cluster-topology.md)'s node
  growth. A service adds an HPA with a documented signal; it is not template default machinery.

## Consequences

### Positive

- A noisy service cannot starve a Core component; eviction order is deterministic.
- Guardrails are namespace-level defaults, not per-service toil.
- Capacity pressure surfaces as quota/`LimitRange` rejections in CI-reviewed manifests, not as 3am OOMs.

### Negative / Risks

- Requests set too low still overcommit; too high waste capacity. Mitigated by observability
  ([ADR-0011](0011-observability.md)) feeding right-sizing over time.
- `ResourceQuota` can block a deploy when a namespace is full — intended back-pressure, but it must be a
  legible failure, not a silent pending pod. `mise run lint:resource-governance` prints per-namespace
  utilisation on every CI run so the cap is approached knowingly.

## Implementation (2026-07-26)

All four guardrails now exist in `infra/helm/platform/resource-governance/`, ordered against each other by
sync-wave inside that chart (PriorityClass -5, LimitRange -4, ResourceQuota/PDB -3) and placed in the
ApplicationSet **base** tier: a LimitRange only defaults pods created *after* it exists, and a pod naming a
PriorityClass that does not exist yet is rejected outright.

Every number is derived from measurement, not taste — taken from `cluster:full` under the
[ADR-0027](0027-load-and-performance-testing.md) load suite and re-derivable from the `load-test` dashboard's
cost table. The headline measurements that changed decisions:

| Workload | Measured peak | Consequence |
|---|---|---|
| Tempo | **1858Mi** (≈400Mi at rest) | The heaviest pod in the cluster; the 512Mi namespace default would have OOM-killed it during exactly the runs meant to observe it. Explicit 3Gi limit. |
| temporal-history | **2121m CPU**, 647Mi | The strongest evidence for the no-CPU-limits rule below: a 500m limit would throttle it to a quarter of measured need, visible only as checkout settle-time collapse. |
| Oathkeeper / Traefik | 192m / 184m CPU | The edge costs ~3× catalog on the read path. Size the edge first. |
| Postgres | 373Mi, 267m CPU | — |
| Loki | 453Mi | 88% of the namespace default; explicit 1Gi. |

### Deliberate gaps

These are **not** oversights, and are recorded here so the documentation and the cluster agree:

- **`kube-system` has a `LimitRange` but NO `ResourceQuota`.** A quota rejects pod *creation*; in
  `kube-system` the rejected pods are the CNI DaemonSet, CoreDNS and the ingress controller, and the
  recourse for a rejected system pod is a working cluster. The blast radius is unbounded and
  self-inflicted, so the line is drawn at objects that can only *add* defaults.
- **No `min` or `max` on any `LimitRange`.** Both reject. An earlier revision set `min.memory: 16Mi`; Cilium's
  `install-cni-binaries` initContainer legitimately requests 10Mi, so that floor would have rejected the CNI
  DaemonSet on every node. Caught by rendering every chart before applying — now `lint:resource-governance`.
- **Only one `PodDisruptionBudget` is enabled.** A PDB with `minAvailable: 1` in front of a *single-replica*
  workload permits zero disruptions and makes `kubectl drain` hang forever (CNPG's own `postgres-primary`
  PDB demonstrates it: `ALLOWED DISRUPTIONS = 0`). On the single-node local tier only `postgres-pgbouncer`
  runs 2 replicas, so it is the only one on. The rest are declared-but-disabled in values as the list a
  multi-node environment enables as it scales those components out.
- **Temporal pods cannot declare a `priorityClassName`** — the upstream chart (temporal-1.4.0) exposes
  per-role `resources` but no priority field. They therefore inherit it from the `globalDefault`, which is
  why `platform-critical` rather than `product` is the default: the workloads that *cannot* declare a
  priority are exactly the ones that need the high one. Workloads we control (`infra/helm/service`) declare
  `product` explicitly to sit below the platform.
- **One CPU limit survives**: `temporal-worker-controller-manager` inherits `limits.cpu: 500m` from its
  subchart, and a parent `values.yaml` cannot delete it (Helm coalesces maps and skips parent nulls; only
  `--set …=null` works, and there is no per-chart `--set` in the shared ApplicationSet template). Accepted
  because 500m is ~80× the measured 6m peak of a leader-elected reconciler. Both this and Cilium's
  init-container limit are allow-listed with reasons in `tools/lint-resource-governance`.
- **Kyverno is listed as a Core component in [`docs/operational-surface.md`](../operational-surface.md) and
  [ADR-0021](0021-supply-chain-security.md) but is not deployed** and appears nowhere in `infra/`. That
  removes the admission-time mutation escape hatch which would otherwise have stamped `priorityClassName`
  onto charts that cannot express it. Recorded here because it is a doc-vs-reality gap this ADR now depends
  on; closing it is ADR-0021's business, not this one's.

### A metric trap worth knowing

`k8s_pod_memory_limit_utilization_ratio` (kubeletstats) divides memory **usage** — which counts reclaimable
page cache — by the limit, and overstates real pressure by 2–3× across every pod measured here
(`otel-cluster` reported 97.9% against a true 58.0%). The OOM killer acts on the **working set**, so limits
are sized against `k8s_pod_memory_working_set_bytes / k8s_container_memory_limit_bytes`, which is what the
`load-test` dashboard computes.

### Follow-ups

- Per-environment `ResourceQuota` overrides: the committed caps are sized for the single-node local tier.
- Enable the declared-but-disabled PDBs as components gain replicas.
- Re-derive requests/limits after any material traffic change; Tempo is the one to watch, since its memory
  scales with trace ingest rate.

## Rules

- Every container declares CPU/memory requests and a memory limit, or lands in a namespace whose
  `LimitRange` supplies them. A container that ends up with neither is a defect.
  `(CI: lint:resource-governance)`
- No container sets a CPU limit unless throttling is genuinely wanted. Inherited ones that cannot be removed
  are allow-listed with a reason in `tools/lint-resource-governance`. `(CI: lint:resource-governance)`
- A `LimitRange` in this platform may only ADD defaults, never reject: no `min`, no `max`. Rejecting a
  third-party pod on a floor we invented is a self-inflicted outage. `(CI: lint:resource-governance)`
- Every namespace we own has a `LimitRange` and a `ResourceQuota`. `kube-system` is the documented exception
  — LimitRange yes, quota never. `(CI: lint:resource-governance)`
- The summed requests and memory limits of a namespace fit inside its `ResourceQuota`, with utilisation
  reported on every run. `(CI: lint:resource-governance)`
- Workloads carry a `PriorityClass`: `platform-critical` > `product` > `batch`; batch is evicted first.
  `platform-critical` is the `globalDefault`, so charts that cannot express a priority inherit the right one;
  product workloads opt *down* explicitly. `(review-only)`
- Every multi-replica or stateful component has a `PodDisruptionBudget` that preserves quorum. A
  single-replica workload gets none — a PDB there permits zero disruptions and hangs `kubectl drain`.
  `(review-only)`
- Requests and limits are derived from measurement ([ADR-0027](0027-load-and-performance-testing.md)), not
  estimates, and the measurement is recorded next to the value. `(review-only)`
- Memory sizing uses the **working set**, never `k8s_pod_memory_limit_utilization_ratio` — that metric counts
  reclaimable page cache and overstates pressure 2–3×. `(review-only)`
- HPA is opt-in per service on a documented sustained-load signal, never a template default. `(review-only)`
