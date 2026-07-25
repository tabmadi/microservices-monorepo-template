# ADR-0006: Durable Execution (Temporal)

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Platform team
- **Related:** [ADR-0000](0000-platform-foundations.md), [ADR-0001](0001-language-and-runtime.md)

## Context

The platform needs one answer to a family of related problems:

- Operations spanning **multiple services or external systems** that must not leave the system half-applied (registration, payment, refund).
- Operations needing **compensation on failure** (sagas).
- **Scheduled / periodic work** — daily reports, hourly reconciliations, cleanup.
- **Background / async work** — emails, thumbnails, indexing, fan-out notifications.
- **Authz-relevant mutations** ([ADR-0010](0010-auth.md)) that write to both the application database and the authorization datastore atomically-in-effect.

Without a single durable-execution platform, each grows its own ad-hoc machinery: outbox tables, dead-letter queues, retry loops, cron jobs, custom idempotency. At 100 services this is unmaintainable.

## Decision drivers

1. **One reliability primitive, not five.** No coexistence of DLQ + cron + ad-hoc retries with a workflow engine. A single sanctioned lighter path — a transactional outbox for trivial best-effort dispatch — is the one deliberate exception, bounded below.
2. **Service boundaries stay HTTP/OpenAPI.** A workflow engine must not become the cross-service bus.
3. **Operationally cheap per workflow.** Adding a workflow must cost less than building the same reliability by hand.
4. **Self-host** ([ADR-0000](0000-platform-foundations.md)).

## Considered options

- **Temporal (self-hosted)** — durable execution as a first-class primitive; mature Go SDK; Postgres-backed; activities, child workflows, signals, queries, timers, schedules, sagas in one model.
- **Restate** — newer, simpler ops model, but young; SDK and saga ergonomics trail Temporal. Worth watching, not adopting.
- **Cadence** — Uber's predecessor to Temporal; less momentum. No upside over Temporal.
- **DIY (outbox + queue + cron + retry loops)** — re-implements Temporal poorly four times.
- **k8s Jobs / CronJobs / Argo Workflows** — pipeline DAGs, not business workflows. Retained for pure infrastructure tasks (DB vacuum, log rotation).
- **Temporal Cloud** — managed; out of scope by the self-host principle. Client SDK call sites are cloud-neutral, so future migration is a deploy change.

## Decision

**Self-hosted Temporal is the platform's durable-execution layer.** It is the single answer to: long-running business workflows, sagas, scheduled jobs, and background async work.

### Scope: when is something a workflow

A workflow is the right primitive when **any** of the following hold:

1. The operation has **2+ logical steps** where partial completion is a bad state.
2. The operation **touches more than one service or external system.**
3. The operation must **compensate on failure**, not just return an error.
4. The operation is **long-lived relative to a request** (the user cannot hold the connection open).
5. The operation must **survive process restarts** by design.

A workflow is the **wrong** primitive when the operation is a single atomic action inside one service. A `PATCH /profile { name }` is not a workflow.

Concrete classification:

| Operation                                                    | Primitive                                    |
|--------------------------------------------------------------|----------------------------------------------|
| Register user (Kratos + orgs + authz tuples + welcome email) | Workflow                                     |
| Checkout (reserve → charge → order → deduct → confirm)       | Workflow                                     |
| Payment (often a child workflow of checkout)                 | Workflow                                     |
| Refund (compensation, multi-system)                          | Workflow                                     |
| Authz-relevant resource mutation (app DB + authz store)      | Workflow — per [ADR-0010](0010-auth.md)      |
| Daily reconciliation job                                     | Workflow — Temporal `Schedule`, not k8s `CronJob` |
| Send transactional email (fire-and-forget)                   | Outbox (or workflow if delivery must be tracked) |
| Generate thumbnail / index document                          | Outbox (or workflow if part of a larger process) |
| Update profile name                                          | Neither — synchronous                        |
| Add item to cart                                             | Neither — synchronous                        |
| List orders                                                  | Neither — synchronous                        |

### Trivial best-effort async: the outbox seam

Not every async job earns a workflow. A **trivial best-effort** job — one that is single-step, owned by one service, and tolerable to lose or retry crudely (a welcome email, a thumbnail) — MAY instead use a **transactional outbox**: the triggering row and an `outbox` row commit in one Postgres transaction, and a small per-service dispatcher drains it. This is the [`docs/operational-surface.md`](../operational-surface.md) Scale seam in reverse — the *lighter* floor for the simple 80%, with Temporal as the default the moment a job grows a second step, a cross-service call, compensation, or a durability guarantee.

A job stays on the outbox only while **all** of these hold; the moment any fails, it is a workflow:

1. single logical step,
2. inside one service (no cross-service or external-system coordination that must not half-apply),
3. best-effort — losing or double-running it is acceptable, so at-least-once dispatch with an idempotent handler suffices,
4. no compensation on failure.

**Honesty caveat.** Only two systems exercise Temporal so far — not enough real usage to harden a blanket "all async is a workflow" law. Temporal is the **default** async primitive; the outbox is the sanctioned lighter path for the trivial case; the blanket rule is revisited once more workflows exist in practice.

### Architecture: co-located workflows, HTTP between services

Workflows, activities, and workers live **inside the service that owns the business process**.

```text
services/<service>/
├── openapi.yaml
├── cmd/{server,worker}/main.go
├── internal/
│   ├── handlers/        # HTTP handlers (from generated server stubs)
│   ├── workflows/       # workflows owned by this service
│   ├── activities/      # activities owned by this service
│   ├── domain/
│   └── store/
└── migrations/
```

**Process-owner rule.** A workflow lives in the service that owns the *business process*, not the service that owns the most data. "Register user" lives in `identity` (or a dedicated `onboarding`) even though it writes to `orgs` and the authz store. "Checkout" lives in `checkout` even though it calls `payment`, `inventory`, and `orders`. A service whose primary job is orchestrating other services is a legitimate shape, not a smell.

**Cross-service workflow invocation: HTTP only.**

1. The owning service exposes an HTTP endpoint that internally starts the workflow.
2. The caller invokes it via the generated client in `libs/go/sdks/<service>/`.
3. The response is `202 Accepted` with a workflow handle conforming to the `WorkflowHandle` schema declared in each service's OpenAPI `components` (see [ADR-0008](0008-api-contracts.md)).

A service never starts another service's workflow directly via the Temporal client; doing so would import the callee's workflow input struct (coupling) and bypass OpenAPI, tracing, and the identity-header contract.

**Waiting on a cross-service workflow.** Pick by need:

1. **Poll the handle.** The owning service exposes `GET /<resource>/{id}` returning `{status, result?}`. The caller's workflow polls with backoff.
2. **Webhook callback.** The caller passes `callback_url`; the owning service POSTs on completion; the caller's workflow waits on a Temporal signal raised by its own webhook handler.
3. **Fire-and-forget.** The caller doesn't need the result.

Direct Temporal signals across service boundaries are not permitted.

### Activity placement

| Scope of use                                          | Location                                                                                                                        | Notes                                                            |
|-------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------|
| One service's workflows only                          | `services/<service>/internal/activities/`                                                                                       | The 90% case.                                                    |
| Generic infrastructure (email, S3, metrics, webhooks) | `libs/go/temporal-activities/<concern>/`                                                                                        | Stateless and service-agnostic. No dependency on `services/...`. |
| Logically owned by another service                    | **Not shared.** Each caller writes a thin activity in its own `internal/activities/` wrapping `libs/go/sdks/<owning-service>/`. | The shared thing is the HTTP API.                                |

Sharing an activity *across services* by putting domain logic in `libs/` is a smell.

### Wall-clock: workflows complete within one deploy cycle

A workflow's wall-clock should fit inside one prod deploy cycle (~1 week per [ADR-0004](0004-gitops.md)). The reason is event-history size and operational legibility — **not** avoiding versioning, which the section below now handles directly.

Long-running workflows (subscription billing, multi-day onboarding nudges, inactivity timers) are permitted but each requires:

1. An entry in `docs/temporal/long-running.md` listing the workflow and its expected wall-clock.
2. Replay tests (`workflow.NewReplayer`) covering historical event histories in CI.
3. If, and only if, the workflow opts out of Pinned into `AutoUpgrade`, a documented `workflow.GetVersion` patching plan — an `AutoUpgrade` execution moves between Deployment Versions mid-flight and is the one case that must stay replay-safe by hand.

Liberal use of workflows for multi-step / compensable / cross-system operations; conservative use of long wall-clocks.

### Deploying workflow code: Worker Deployment Versioning

Changing workflow code under a running execution is the failure mode this section exists for: a workflow started before a deploy is resumed by a worker running after it, and if the code no longer replays the recorded history the execution dies with a non-determinism error. A short wall-clock shrinks the exposure window but does not close it — a checkout that runs for thirty seconds can still be mid-flight when a worker rolls.

**Workers run versioned, and Workflows are Pinned by default.** Each worker declares a Worker Deployment Version (a deployment name plus a Build ID); the server routes new executions to whichever version is *Current*, and a Pinned execution then runs start-to-finish on the version that began it. A deploy therefore cannot break in-flight work, and the ordinary case needs no `workflow.GetVersion` at all. Temporal's own guidance is that versioning, not patching, is the default for production; patching remains the fallback where versioned deployment is impossible.

Three consequences worth stating plainly, because each one has bitten:

- **The Build ID must track the code, not the release channel.** The controller derives it from the container image tag plus a hash of the pod template, so a configuration-only change — a new env var, a changed resource limit — is also a new Deployment Version. That is stricter than deriving it from the image alone ([ADR-0013](0013-release-and-versioning.md)) and is why the chart no longer computes it.
- **A pin is only as good as the pods behind it.** Pinning a workflow to a version it can no longer reach is worse than not pinning it: the execution does not fail over to the new code, it simply waits. A plain rolling `Deployment` deletes the old version's pods the instant the rollout completes, so the protection would last only as long as the rollout overlap — seconds — rather than the workflow's lifetime. Workers are therefore `WorkerDeployment` custom resources reconciled by the **Temporal Worker Controller**, which keeps one Kubernetes Deployment per Build ID alive until Temporal reports that version Drained, and only then scales it down and deletes it. This is the "rainbow deploy" shape, and it is the reason the operator is worth its footprint: retaining a version until its work finishes depends on drainage state that only Temporal knows and that changes long after the sync ends, so it is reconciler work, not something a chart can template.
- **Promotion is the controller's job, not the pipeline's.** The controller registers each version, promotes it per `rollout.strategy`, and injects `TEMPORAL_DEPLOYMENT_NAME` / `TEMPORAL_WORKER_BUILD_ID` itself — upstream is explicit that those must not be set by hand. Rollback is `temporal worker deployment set-current-version` against the previous Build ID, which still has running pods precisely because sunset is delayed.
- **Sessions and versioning are mutually exclusive.** The SDK refuses `EnableSessionWorker` together with versioning, so a service that genuinely needs sessions opts out of versioning explicitly (`worker.versioning.enabled: false`) and owes a patching plan instead.
- **Deleting a `WorkerDeployment` blocks while its workers are still polling.** The CR carries a `temporal.io/delete-protection` finalizer; on delete the controller asks Temporal to remove each Deployment Version, and Temporal refuses with `cannot be deleted since it has active pollers` for as long as pods of that version exist — and for a further poller-expiry window after they are gone. The controller retries indefinitely, so the CR sits `Terminating` and ArgoCD cannot recreate it. Removing a worker (renaming a service, flipping `worker.enabled` off, pruning) therefore means scaling the versioned Deployments to zero first and waiting for pollers to expire. The break-glass is `kubectl patch workerdeployment <name> --type merge -p '{"metadata":{"finalizers":null}}'`, which leaves the Temporal-side version records behind to age out.

### Draining a worker on rollout

Distinct from replay safety, and routinely confused with it: when a worker pod is rolled, activities *currently executing* are lost unless the worker is told to wait. The Go SDK's `WorkerStopTimeout` defaults to `0s` — no wait — so the platform sets it explicitly, and the chart derives the pod's `terminationGracePeriodSeconds` from it so kubelet always waits strictly longer than the worker does. Configuring the grace period independently is how this silently regresses.

### Replacement of legacy patterns

- **Multi-step / cross-service outbox machinery → workflows.** When a downstream effect must not leave the system half-applied, the application DB write and the downstream effect are activities in the same workflow — not a hand-rolled outbox with its own retry loop. The transactional outbox survives only for the trivial best-effort case defined above.
- **Event bus (NATS / Kafka) — not adopted.** HTTP + Temporal signals (via webhook callbacks where needed) cover cross-service notification. A true pub/sub fan-out need gets its own ADR.
- **k8s CronJobs → Temporal Schedules** for any business-meaningful periodic task. k8s CronJobs remain for pure infrastructure (DB vacuum, log rotation).
- **Background queues → workflows** on a `background-tq` task queue, except trivial best-effort jobs on the outbox seam.

### Operational shape

- **Server:** Temporal monolith binary (all four roles in one process) deployed via Helm at `infra/helm/platform/temporal/`. Backed by the platform Postgres (separate database, same cluster).
- **Workers:** one worker deployment per service at `services/<service>/cmd/worker/`. Registers only the workflows and activities owned by that service. Ships and deploys with its service.
- **Task queues:** named per-service (e.g. `payments-tq`, `checkout-tq`), plus a shared `background-tq`.
- **Namespaces:** one per environment (`dev`, `staging`, `prod`).
- **History retention:** 30 days production, 7 days non-prod.
- **Local development:** the inner loop uses `temporal server start-dev` (`mise run cluster:lite`) for speed; the
  full-platform local tier (`mise run cluster:full`) runs this same Helm chart at a single replica, Postgres-backed via
  CNPG, so workflow behaviour is validated against the real server before merge ([ADR-0016](0016-environment-parity.md)).

### Conventions

- **Workflow code is deterministic.** No `time.Now()`, no `math/rand`, no direct I/O, no goroutines (use `workflow.Go`). Side effects go through activities. A `workflowcheck` analyzer runs in CI.
- **Activities are idempotent.** Every activity tolerates being invoked twice with the same input. The workflow run ID + activity ID is the natural idempotency key for external calls.
- **Activity inputs and outputs are small** (kilobytes, not megabytes). Large payloads go through the off-cluster bucket from [ADR-0003](0003-cluster-topology.md); activities pass references.
- **Timeouts are explicit.** Default activity `StartToCloseTimeout = 30s`, default workflow `WorkflowExecutionTimeout = 1h`. Overrides require justification in the workflow file.
- **Errors are typed** via `temporal.NewApplicationError` with stable error types; retry policy keys off them.
- **Workflow IDs encode business intent.** `payment-{order_id}`, not `payment-{uuid}`. Idempotency is a property of the business operation.
- **No SDK calls outside** `services/<service>/internal/workflows/` and `…/internal/activities/`.

### Cross-cutting integrations

Authz dual-write discipline is [ADR-0010](0010-auth.md)'s; the `WorkflowHandle` response shape is [ADR-0008](0008-api-contracts.md)'s;
service-to-service identity propagation on activity calls is [ADR-0010](0010-auth.md)'s (forwarded identity headers,
gated by Cilium NetworkPolicy — no per-call token); trace propagation through workflows and activities is
[ADR-0011](0011-observability.md)'s default. Nothing here overrides those.

## Consequences

### Positive

- One reliability primitive answers four problems. Engineers learn Temporal once; no second runtime to operate.
- Saga compensation is boring, the highest praise distributed transactions can receive.
- Hand-rolled multi-step outbox machinery disappears as a concept; the outbox survives only as the deliberate lighter path for trivial best-effort jobs.
- Authz dual-write risk ([ADR-0010](0010-auth.md)) is structurally solved, not policed.
- Service boundaries remain HTTP / OpenAPI.

### Negative / Risks

- Non-determinism rules are a real cognitive tax. Mitigated by `workflowcheck`, code-review checklist, and PR template — and, for the specific case of deploying under running executions, by Pinned versioning, which removes the need to reason about replay compatibility at all.
- Versioning adds an operator to the platform's operational surface, and with it a webhook in the admission path and a reconciler that can fall behind. A stalled controller means new worker versions are never promoted — new executions have nowhere to run — so it is a genuine dependency of the deploy path, not a background convenience.
- Old Deployment Versions linger while their Pinned executions drain, so a service runs more than one worker version at once for as long as `sunset` allows. This is the feature working, but pod count and Temporal's version list are larger than the naive desired state, and a version whose workflows never finish never drains — a long-lived workflow can therefore pin a version indefinitely. That is the real cost of the ~1 week wall-clock rule being a rule.
- Temporal server is critical infrastructure. Mitigated by HA Postgres and replay tests proving workflows tolerate restarts.
- Per-activity latency (typically tens of milliseconds) rules workflows out of sub-100ms request paths. The scope rule already excludes those.
- One worker deployment per service multiplies pod count. Accepted; preserves ownership.

### Follow-ups

- `infra/helm/platform/temporal/` deployment with Postgres backing.
- `libs/go/temporalmw/` shared client config, default retry policies, tracing middleware, replay-test scaffolding.
- `mise run cluster:lite` (via `infra/local/deps.yaml`) brings up Temporal alongside other local infra.
- `golangci-lint` config including `workflowcheck`.
- `docs/temporal/long-running.md` registry (initially empty).
- Standard `202 Accepted` workflow-handle shape, declared inline as the `WorkflowHandle` schema in each service's `openapi.yaml` `components`.

## Rules

- Temporal is the platform's durable-execution mechanism and the default async primitive. No DLQs, ad-hoc retry loops, or cron jobs for business-meaningful periodic work. The one sanctioned lighter path is a transactional outbox for trivial best-effort jobs (single-step, single-service, best-effort, no compensation); anything else is a workflow.
- A workflow exists if the operation matches at least one of the five scope criteria above. A trivial best-effort job that matches none MAY use the outbox seam instead of a workflow.
- Workflows, activities, and the worker for a service live under `services/<service>/`. There is no top-level workflow directory.
- Cross-service workflow invocation is HTTP through the generated client. Direct Temporal-client calls across service boundaries are forbidden.
- Cross-service result wait is one of: poll the handle, webhook callback, fire-and-forget. Direct cross-service Temporal signals are forbidden.
- Activities are placed by ownership: in-service for service-specific logic, in `libs/go/temporal-activities/` for stateless infrastructure, never shared across services as a domain wrapper.
- Workflow wall-clock fits within one prod deploy cycle (~1 week) by default. Longer wall-clocks require an entry in `docs/temporal/long-running.md` with replay tests. (review-only)
- Workers run with Worker Deployment Versioning enabled and a default versioning behaviour of Pinned. Disabling it (`worker.versioning.enabled: false`) is permitted only where the SDK forbids the combination — a service using Temporal sessions — and obliges that service to a documented `workflow.GetVersion` patching plan. (review-only)
- A versioned worker is a `WorkerDeployment` reconciled by the Temporal Worker Controller, never a plain `Deployment`. A rolling Deployment deletes the previous version's pods on completion, which strands the Pinned executions the versioning exists to protect. (review-only)
- Build IDs and the `TEMPORAL_DEPLOYMENT_NAME` / `TEMPORAL_WORKER_BUILD_ID` env vars are set by the controller alone. A chart that injects them by hand fights the reconciler and produces versions that do not match the pods running them. (review-only)
- Sunset delays (`sunset.scaledownDelay` / `deleteDelay`) are only ever lengthened, never shortened toward zero. Reclaiming a version before Temporal reports it Drained re-creates the stranding this design removes. (review-only)
- A workflow that opts into `AutoUpgrade` owes a `workflow.GetVersion` patching plan and replay tests, because it moves between Deployment Versions mid-execution. (review-only)
- Worker graceful-stop is configured, and the pod's `terminationGracePeriodSeconds` is derived from the worker stop timeout rather than set independently. (review-only)
- Workflow code is deterministic; side effects go through activities; the `workflowcheck` analyzer enforces this in CI.
- Activities are idempotent and accept retries.
- Workflow IDs encode business intent (`payment-{order_id}`), not opaque UUIDs.
- Activity inputs and outputs stay in kilobytes; larger payloads go through the off-cluster bucket via reference.
- Periodic business-meaningful work uses Temporal `Schedule`. k8s `CronJob` is reserved for pure infrastructure tasks.
- Temporal Cloud is not used. The self-hosted server is the platform's runtime.
