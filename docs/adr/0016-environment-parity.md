# ADR-0016: Environment Parity & Local Tiers

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Platform team
- **Related:** [ADR-0000](0000-platform-foundations.md), [ADR-0003](0003-cluster-topology.md), [ADR-0004](0004-gitops.md), [ADR-0005](0005-secrets.md), [ADR-0007](0007-data.md), [ADR-0011](0011-observability.md)

## Context

[ADR-0003](0003-cluster-topology.md) commits to parity at the artifact layer: production is **k3s on plain compute**,
local is **k3d (k3s-in-Docker)**, and the same Helm charts and manifests apply. That leaves three questions this ADR
answers precisely:

- **What may differ** between an engineer's laptop and production, and what may never differ.
- **How the local cluster is composed** when different roles need different subsets of the platform (a frontend
  engineer iterating on RUM dashboards, a backend engineer debugging one service, an operator running a full
  end-to-end test).
- **Where GitOps fits locally**, given ArgoCD reconciles committed git state, not a working tree.

## Decision drivers

1. **Parity is at the artifact layer.** Same charts, same images, same code, same commands. Differences are declared as
   per-env values, never as forked manifests or chart logic branching on environment.
2. **Two different local jobs.** "Iterate on my code fast" and "validate the whole platform behaves like prod" are
   distinct goals with opposite optimisation targets (speed vs fidelity). One local tier cannot serve both well.
3. **Uphold existing ADRs.** [ADR-0003](0003-cluster-topology.md) (external bucket + off-cluster backups in prod) and
   [ADR-0005](0005-secrets.md) (one secret mechanism everywhere) stand unchanged.
4. **Composition over forks.** A role-specific local, or a new environment, is a thin values selection — not a new
   script or a copied manifest set.

## Decisions

### Parity model: same charts, per-env values only

Every environment — **local, dev, staging, prod** — deploys the same charts under `infra/helm/platform/*` and
`infra/helm/service`. The only sanctioned divergence is a per-env values overlay (`infra/gitops/platform/<env>/values.yaml`,
with local as a first-class member). A divergence that cannot be expressed as a value — a different chart, or a
hand-written Deployment standing in for an operator-managed component — is permitted **only** in the inner-loop tier
below, and never silently.

The **contract never differs in any tier**: the Kubernetes API, the service chart, the service images, and the env
contract (`DATABASE_URL`, `TEMPORAL_HOST_PORT`, OTLP endpoint, OpenFGA) are identical everywhere. What may differ is
*scale* (replica counts, storage), and — in the inner loop only — the *implementation behind a contract*.

### Two local tiers

Local is two tiers with different jobs:

| Tier | Command | Parity | What runs | For |
|------|---------|--------|-----------|-----|
| **Inner loop** | `cluster:lite` + `dev:forward` + **native run** | **interface** | k3d + lightweight dependency stand-ins (`infra/local/deps.yaml`); the service under change runs natively on the host | day-to-day coding |
| **Full platform** | `cluster:full` | **implementation** | k3d + the real platform charts at `instances=1` (CNPG, the Temporal chart, OpenFGA, MinIO, the observability stack, the edge + auth) | end-to-end tests ([ADR-0018](0018-testing-strategy.md)), pre-merge validation, CI, label-gated per-PR preview |

The **inner loop** optimises for speed. The service under change runs **natively on the host** (any editor/IDE, or
`go run`) against lightweight stand-ins (a plain Postgres, `temporal server start-dev`, in-memory OpenFGA; see
[ADR-0003](0003-cluster-topology.md), [ADR-0006](0006-temporal.md)) reached through `dev:forward` port-forwards. The
stand-ins are acceptable because they honour the same wire contract — a bug reproduced against them reproduces in prod.
There is no image build, in-cluster redeploy, or file-watch on the hot path; the full platform is not running, so the
loop is fast and light.

The **full platform** optimises for fidelity. It runs the **same charts production runs**, scaled to a single replica
through the `local` values overlay — CNPG (not a plain Postgres pod), the Temporal Helm chart (not `start-dev`), the
OpenFGA chart, in-cluster MinIO, and the observability stack. This is the tier that catches operator behaviour, sync
ordering, and chart wiring before code reaches a deployed environment, and it is the exact configuration CI and per-PR
preview environments use. It is also the environment the end-to-end and visual suites run against ([ADR-0018](0018-testing-strategy.md)):
the full e2e suite nightly + pre-release, a smoke subset on label-gated per-PR previews.

### Distribution tiers: k3d (ephemeral) vs k3s (persistent)

`k3d` and `k3s` run identical charts, so the choice is lifecycle, not architecture:

| Tier | Distribution | Lifecycle |
|------|--------------|-----------|
| local (both loops) | k3d | per-engineer, recreated freely |
| CI e2e / label-gated per-PR preview | k3d | ephemeral, created and destroyed per run |
| dev / staging / prod | k3s on compute | persistent ([ADR-0003](0003-cluster-topology.md)) |

The full-platform local tier and the CI/preview tier are the **same configuration**; investment in one is investment in
the other. Persistent dev/staging stay on k3s-on-compute — they survive reboots and hold real storage and backups, and
they are not managed Kubernetes, so there is no control-plane bill to cut by moving them to k3d.

### Local composition: profiles (what platform runs) vs modules (what I iterate on)

Two independent axes, resolved by two independent mechanisms:

- **What platform components are up** — a small set of named **profiles**, each naming a subset of the platform's
  components. A profile is a **selection, not a copy**: every component it brings up is the same chart with the same
  `infra/gitops/platform/local/values.yaml` overlay the full tier uses, and the shared stand-in manifest
  (`infra/local/deps.yaml`) is sliced by the `local.platform/component` label rather than forked. So there is exactly one
  local values file, and a profile cannot drift from the tier above it:

  | Profile | Components up | Typical user |
  |---------|---------------|--------------|
  | `min` | Postgres only | backend, no workflows |
  | `backend` | + Temporal + OpenFGA | backend with workflows |
  | `edge` (`cluster:edge`) | Traefik + cert-manager + Kratos + Oathkeeper + Postgres, application data served by the API mock ([ADR-0029](0029-api-mocking-and-ui-dev-loop.md)) | frontend building authenticated UI |
  | `obs` | observability + Faro/Grafana | frontend RUM / dashboards |
  | `full` | everything | operator end-to-end |

  The `edge` profile is the one that inverts the usual mock/real split: the identity and edge
  components stay **real** because they are cheap and their behaviour (cookies, CSRF, session
  expiry, AAL, `401`/`403`) is exactly what a UI must be built against, while the application
  services — the expensive part — are replaced by their own OpenAPI contract. It is the reason the
  frontend needs no development-only authentication code
  ([ADR-0014](0014-frontend.md), [ADR-0029](0029-api-mocking-and-ui-dev-loop.md)).

- **Which service I iterate on** — in the inner loop you run exactly one service natively (the one under change); the
  rest are stand-ins or absent. When a service must run *in* the cluster (edge/auth/e2e), `service:deploy -- <svc>` does a
  one-shot build-import-upgrade ([ADR-0003](0003-cluster-topology.md)). This axis never leaks into platform composition.

Profiles stay a handful of composable selections, not per-engineer snowflakes. ArgoCD is the engine for `full` only;
the lighter profiles are applied imperatively for the same reason the inner loop is (see below), which is also why
`edge` runs the ephemeral Postgres stand-in rather than CNPG.

### GitOps locally: inner loop is native, full tier is ArgoCD

ArgoCD reconciles committed git state, so it is **not** the inner loop's engine — the inner loop runs the service
natively against `cluster:lite`'s stand-ins ([ADR-0004](0004-gitops.md)). The **full-platform tier does run ArgoCD**: a
local bootstrap (`infra/gitops/local-bootstrap/`) applies the same app-of-apps prod uses, syncing committed `master`
from the remote, so sync ordering, app discovery, and secret materialisation are exercised exactly as in prod. Only the
two genuine bootstrap components ArgoCD cannot self-create — the CNI (Cilium) and ArgoCD itself — are installed
imperatively by `cluster:full` before the root-app is applied; everything else is Argo-managed.

Two escape hatches cover iterating on uncommitted infra (a rare day):

- **Chart/value change:** `platform:deploy -- <chart>` pauses Argo auto-sync on that one app and `helm upgrade`s it from
  the working tree.
- **GitOps-wiring change** (sync-waves, ApplicationSets, App defs): push a branch and point the local root-app
  `targetRevision` at it — this exercises the real delivery path, which `helm` cannot.
- **CNI/CRD change** (e.g. Cilium): prefer `cluster:delete` + a fresh `cluster:full` over an in-place upgrade — hot-
  swapping a CNI on a live cluster blips networking. This is inherent to the component, not a tooling gap.

This is what makes the full tier a true e2e rehearsal rather than a hand-rolled approximation.

### Object storage: MinIO (S3 API) in non-prod, external bucket in prod

[ADR-0003](0003-cluster-topology.md) stands: **no MinIO in production**, **backups off-cluster and mandatory**. The
interface is the S3 API in every environment; the provider differs by values:

- **local / dev / staging:** in-cluster MinIO (`infra/helm/platform/minio`).
- **prod:** an external S3-compatible bucket. In-cluster object storage in prod would co-locate data and its backups on
  the same nodes, defeating disaster recovery.

CNPG backups target the external bucket in prod; in non-prod they may target the in-cluster MinIO for self-containment
(non-prod backups are convenience, not a recovery guarantee). The only per-env delta is the S3 endpoint and whether the
MinIO chart is enabled.

### Secrets: SOPS everywhere

[ADR-0005](0005-secrets.md) requires one secret mechanism in every environment. Local is no exception: the same SOPS
path, with a committed, well-known **local** age key — safe precisely because the only values it decrypts are throwaway
dev credentials. The decrypt mechanism is identical to prod; only the plaintext differs.

### Local domain: `*.localtest.me`

`localtest.me` is real public DNS resolving to `127.0.0.1` with zero host configuration. `.local` is reserved for mDNS
([RFC 6762](https://www.rfc-editor.org/rfc/rfc6762)) — it collides with Avahi/Bonjour and does not resolve to loopback
without `/etc/hosts` or mDNS. `*.localhost` / `*.test` signal "local" more loudly but need a modern resolver or a hosts
entry. The frictionless default wins; the `dev.` prefix already marks it non-production.

### What is local-only by nature

A small, enumerated set of manifests has no production analogue, and each states why:

- `infra/local/deps.yaml` — the inner-loop dependency stand-ins. The full tier does not use it.
- `infra/local/traefik-config.yaml` — tunes the k3s-bundled Traefik (cross-namespace refs). Prod runs its own Traefik
  (the Ansible `k3s_server` role disables the bundled one).
- `infra/local/edge-auth.yaml` — routes `/auth` + landing to a host-run `next dev`, a dev-loop convenience
  ([ADR-0014](0014-frontend.md)); prod deploys the built frontend image in-cluster.
- `infra/local/mock.yaml` — the API mock serving the committed OpenAPI projection on `/api` in the
  `edge` profile ([ADR-0029](0029-api-mocking-and-ui-dev-loop.md)). It runs on no other tier and in
  no deployed environment.
- A self-signed wildcard TLS issuer instead of cert-manager + Let's Encrypt — the same cert-manager mechanism, a local
  ClusterIssuer.

## "May differ" vs "must not differ"

| Concern | May differ across envs | Must NOT differ |
|---------|------------------------|-----------------|
| Kubernetes distribution | k3d (ephemeral) vs k3s (persistent) | the charts and manifests applied |
| Scale | replicas, storage size, anti-affinity, HPA | which components the full tier runs |
| Data-tier implementation | inner-loop stand-ins vs the real charts | the wire contract (`DATABASE_URL`, Temporal gRPC, OpenFGA), the Postgres major |
| Object storage provider | MinIO (non-prod) vs external bucket (prod) | the S3 API contract |
| TLS issuer | self-signed (local) vs Let's Encrypt (deployed) | cert-manager as the mechanism |
| Secret plaintext | throwaway (local) vs real | SOPS as the decrypt mechanism |
| Domain | `*.localtest.me` vs `*.<env>.<project-domain>` | the routing / edge shape |

## Consequences

- **The full-platform local tier validates the same software prod runs** — operators, sync ordering, and chart wiring,
  not just the services. A chart change is exercised end-to-end before it reaches a deployed environment.
- **The inner loop stays fast.** Engineers who only need to run code keep the lightweight stand-ins; the heavy tier is
  opt-in via `cluster:full` and narrowed further by profiles.
- **`infra/local/` is a short, justified list** — inner-loop deps plus the genuinely-local edge shims — not a parallel
  copy of the platform.
- **The full tier costs laptop RAM.** Running CNPG + the Temporal chart + the observability stack at once is heavier
  than the inner loop; profiles exist precisely so a role runs only the slice it needs.
- **New environments and role-locals are values selections.** Adding one is an overlay, not a script.
