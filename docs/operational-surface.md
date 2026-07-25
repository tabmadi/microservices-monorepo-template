# Operational Surface & Component Tiers

This document is the running inventory of every platform component the template
operates, sorted into three tiers, plus the budget rule that governs adding to
the always-on floor. It makes [ADR-0000](adr/0000-platform-foundations.md)'s
"operational surface dominates over feature breadth" principle checkable rather
than aspirational.

The unit that matters at the target scale (~100 services, 3–8 engineers) is not
the raw component count — most of these components are the honest production
floor for a multi-tenant application at meaningful load. The unit that matters is
**operational surface a small team must understand at 3am**. Tiering makes that
surface explicit and bounded.

## The three tiers

### Core — always on

The real floor. Every environment runs these; a project removes one only by
writing an ADR that shows the floor already covers its concern.

| Component | Concern | ADR |
|---|---|---|
| k3s | Kubernetes runtime | [0003](adr/0003-cluster-topology.md) |
| Cilium (+ WireGuard, default-deny) | CNI, east-west encryption, network policy | [0003](adr/0003-cluster-topology.md) |
| Traefik | Ingress / edge routing | [0009](adr/0009-api-gateway.md) |
| cert-manager | TLS certificate lifecycle | [0003](adr/0003-cluster-topology.md) |
| CloudNativePG (CNPG) | Postgres | [0007](adr/0007-data.md) |
| ArgoCD | GitOps reconciliation | [0004](adr/0004-gitops.md) |
| Kratos | Identity / authentication | [0010](adr/0010-auth.md) |
| Oathkeeper | Edge authorization (forward-auth) | [0009](adr/0009-api-gateway.md), [0010](adr/0010-auth.md) |
| sops-operator | Secret decryption | [0005](adr/0005-secrets.md) |
| Kyverno | Admission policy (image signatures, digest pins) | [0021](adr/0021-supply-chain-security.md) |
| OpenFGA | Authorization (ReBAC) | [0010](adr/0010-auth.md) |
| Temporal | Durable execution | [0006](adr/0006-temporal.md) |
| Temporal Worker Controller | Versioned (rainbow) worker deploys — one Deployment per Build ID, retained until drained | [0006](adr/0006-temporal.md) |
| Loki | Log storage | [0011](adr/0011-observability.md) |
| Tempo | Trace storage | [0011](adr/0011-observability.md) |
| Prometheus | Metrics storage | [0011](adr/0011-observability.md) |
| OTel Collector | Telemetry collection (DaemonSet) | [0011](adr/0011-observability.md) |
| MinIO | Object storage (non-prod; a real bucket in prod) | [0016](adr/0016-environment-parity.md) |
| Lowdefy admin | Internal ops CRUD over the Go API | [0012](adr/0012-internal-admin.md) |
| Headlamp | Read-mostly Kubernetes debug UI | [0024](adr/0024-kubernetes-debug-ui.md) |
| Hubble UI | Live service map, network flows, drop verdicts (bundled with Cilium) | [0025](adr/0025-service-map-apm-ui.md) |
| pgweb | Read-only break-glass DB inspector | [0012](adr/0012-internal-admin.md) |

### Scale — documented swap-in when a real signal demands it

These are not shipped by default. Each is a variant the Core floor grows into
when a measured signal appears. The seam and the trigger are documented so the
swap is a values change, not a re-architecture.

| Swap | From (Core) | Trigger |
|---|---|---|
| **Mimir** | Prometheus | Metrics need multi-tenant isolation, HA, or long-retention object-storage-backed durability. Prometheus local TSDB is the floor; Mimir is the horizontally-scalable Prometheus-compatible successor — same query API, same dashboards, same alert rules, so the swap touches storage config, not instrumentation. |
| **Temporal for trivial async** | Outbox + small worker | A best-effort job (thumbnail, fire-and-forget email) grows a multi-step, cross-service, or durable-retry requirement. Temporal is already Core; this seam only governs whether a *given* trivial job earns a workflow. See [ADR-0006](adr/0006-temporal.md). |
| **OTel Collector gateway tier** | DaemonSet only | Trace volume justifies tail sampling (holding spans to promote slow traces after the fact). Additive: services always emit to `localhost:4317`, so the gateway is a deploy, not a code change. See [ADR-0011](adr/0011-observability.md). |
| **LGTM microservices mode** | Monolithic single-binary | A single backend's ingest volume outgrows one Deployment. Object storage already holds the data, so the split is a values change, not a data migration. |

### Opt-in — flag-gated, off unless a project asks

Real components that most instances never need. Gated behind a project flag, the
same pattern as `hydra_thirdparty`.

| Component | Concern | Flag / ADR |
|---|---|---|
| Hydra | OAuth2 provider for third-party API clients | [0010](adr/0010-auth.md) |

## Budget rule

The floor is not free. Every Core component is a system a small team must be able
to reason about during an incident. So:

- **Nothing joins Core without answering "does the floor already cover this?"**
  A new always-on component must show that no existing Core part serves its
  concern. If an existing part covers 90% of the need, that is the answer.
- **Prefer the Core floor over a Scale variant until a measured signal appears.**
  Picking the scale-tier variant of a component before scale exists is the
  template's characteristic over-commitment. Ship the floor; document the seam.
- **A Scale swap needs a written trigger**, not a preference. The trigger is a
  measurable condition (ingest volume, tenant count, retention window), stated in
  the table above and in the owning ADR.
- **An Opt-in component ships off.** It carries no operational surface until a
  project flips its flag, at which point that project owns its runbook.

This budget is the operational form of [ADR-0000](adr/0000-platform-foundations.md)
principle 2's soft-exit: the self-host cost-benefit holds while the team can
absorb the Core floor. When operating the floor consistently crowds out feature
work, the response is to reconsider a Core component per its ADR — not to keep
adding.
