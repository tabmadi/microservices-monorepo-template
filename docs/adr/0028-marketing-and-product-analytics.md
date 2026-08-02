# ADR-0028: Marketing & Product Analytics

- **Status:** Proposed
- **Date:** 2026-07-26
- **Deciders:** Platform team
- **Related:** [ADR-0000](0000-platform-foundations.md), [ADR-0008](0008-api-contracts.md), [ADR-0009](0009-api-gateway.md), [ADR-0010](0010-auth.md), [ADR-0011](0011-observability.md), [ADR-0014](0014-frontend.md), [ADR-0017](0017-url-and-domain-structure.md), [ADR-0021](0021-supply-chain-security.md), [ADR-0023](0023-data-lifecycle-privacy.md)

## Context

The platform has no instrument for the people who acquire its users. Marketing needs three
things, which are usually conflated and are not equally cheap:

- **Acquisition and journey** — where a visitor came from, which page they entered on, what
  they navigated through.
- **Engagement and conversion** — time on page, clicks, custom events, and the funnel and
  retention questions built on them.
- **Session replay** — watching a recorded session to see why someone dropped off.

And one requirement that turns out to dominate all three: **an error must be connectable to the
journey that produced it.**

The platform already collects browser signals. [ADR-0014](0014-frontend.md) ships Grafana Faro
in `apps/frontend/`, POSTing to `/api/rum`, through Traefik into the OTel Collector's `faro`
receiver, landing in Loki and Tempo alongside service telemetry
([ADR-0011](0011-observability.md)). That apparatus answers *"is it broken or slow"* and was
never built to answer *"did the campaign convert."* Loki does counts adequately and funnels
badly — no step joins, weak distinct-over-window — and marketing wants months of retention
where ops logs want days.

The binding constraint is the correlation requirement, and it eliminates most of the market
before features are compared. Every standalone analytics product — Umami, Plausible, Matomo,
Rybbit, OpenPanel, PostHog — mints **its own session identity in its own store with its own
retention.** Faro mints another. There is no join key, so "this user hit an error, show me their
journey" degrades to correlating on timestamp and IP, which [ADR-0023](0023-data-lifecycle-privacy.md)
makes worse rather than better. Bolting an analytics tool alongside Faro does not produce the
stated requirement at any price.

So the decision is not *which analytics tool*. It is **which store holds Faro's events**.

## Decision drivers

1. **Correlation by construction, not by join.** One browser agent means one session identity,
   and correlation stops being a feature to build.
2. **This platform makes services cheap and components expensive.** Per-service cost is the
   thesis of [ADR-0000](0000-platform-foundations.md); a platform component pays the full
   [ADR-0020](0020-resource-management.md) / [ADR-0021](0021-supply-chain-security.md) /
   Cilium / backup tax. Capability belongs in a service.
3. **PII discipline is already decided.** [ADR-0011](0011-observability.md) forbids PII in logs,
   metrics and traces; [ADR-0023](0023-data-lifecycle-privacy.md) requires a declared data class,
   schema-level PII tagging, and reachability by the erasure and DSAR workflows. An analytics
   store must satisfy both on day one, not be retrofitted.
4. **Marketing must self-serve without ops-tier access.** [ADR-0017](0017-url-and-domain-structure.md)
   gates every `*.ops.<host>` tool behind the `operator` role and an AAL2 session. Marketing are
   not operators, and Grafana is not their tool.
5. **Collection stays vendor-neutral.** [ADR-0011](0011-observability.md) principle 1 — the
   backend is the replaceable part.

## Considered options

- **A standalone web-analytics component (Umami, Plausible CE, Matomo, Rybbit, OpenPanel).**
  Rejected: each mints a separate session identity, so the correlation requirement fails
  regardless of feature set. Independently, most add a datastore the platform does not have —
  ClickHouse for Plausible/Rybbit/OpenPanel, MariaDB for Matomo — and Matomo's headline
  features (funnels, heatmaps, replay, A/B) are paid plugins, not free core.
- **PostHog self-hosted.** Rejected: Kubernetes self-host is sunset upstream, leaving an
  unversioned image shipping continuously from master — irreconcilable with
  [ADR-0021](0021-supply-chain-security.md)'s digest-pin and signature admission policy, which
  exists precisely to forbid floating, untested dependencies. It would also add roughly eight
  mostly-stateful systems (ClickHouse, Kafka, Redis, a second Postgres, an object store, web
  and worker tiers) against a Core floor of ~23, with a self-authored and permanently
  self-maintained Helm chart, for one team's reporting.
- **PostHog Cloud.** The closest product fit: native OpenTelemetry ingest, `distinct_id` and
  `session_id` auto-attached to logs, and a direct jump from an exception to the replay. Rejected
  as the default because the data leaves the estate and it means operating two RUM agents on one
  frontend. **Retained as the documented escape hatch** (see *Consequences*).
- **OpenReplay self-hosted.** Maintained Helm charts, versioned releases, and the best replay in
  the category. Rejected for acquisition and engagement: a 2 vCPU / 8 GB / 50 GB floor plus its
  own bundled Postgres, Redis and ClickHouse, and correlation to *our* Tempo traces is
  integration work rather than a native join. Reconsidered only if the replay trigger below fires.
- **Loki as the analytics store.** Viable for a first week, rejected as an endpoint: no funnel
  step joins, and routing identity-bearing marketing events into the log store would breach
  [ADR-0011](0011-observability.md)'s PII rule.

## Decision

### 1. One browser agent, one session identity

Faro remains the **only** browser agent. Marketing events are emitted through
`faro.api.pushEvent` under a reserved `marketing.*` name namespace, alongside the existing
`obsLog` helpers in `apps/frontend/src/lib/observability/client.ts`. No second SDK is added.

Correlation is therefore not something this ADR builds; it is a consequence of refusing to add a
second agent. An exception in Tempo, a RUM log in Loki, and a funnel step in the analytics store
all carry the same Faro session ID and the same W3C trace context.

### 2. The split happens at the Collector, not in the browser

A `routing` connector in the existing DaemonSet Collector
(`infra/helm/platform/observability/values.yaml`) evaluates an OTTL condition on the event name
and diverts `marketing.*` events out of the Loki logs pipeline into an OTLP exporter aimed at
`services/analytics/`. Ops signals — errors, Web Vitals, traces — are untouched.

This placement is deliberate and does three things at once: marketing events **never reach
Loki**, so [ADR-0011](0011-observability.md)'s PII rule holds for the log store; marketing data
gets its own retention class instead of inheriting the ops-log one; and the browser stays
ignorant of the topology, so the analytics backend can be replaced without a frontend release.
It is additive configuration on a component already running — no gateway tier, no new component.

### 3. The store is a service, not a platform component

`services/analytics/` is an ordinary first-party service built from `services/_template/`:
a partitioned events table in the existing CNPG cluster, `sqlc` queries, dbmate migrations, an
OpenAPI spec at `x-audience: internal` ([ADR-0008](0008-api-contracts.md)), deployed by the
shared service chart. Funnels, retention and cohorts are SQL window functions over that table;
pre-aggregated rollups are refreshed by a Temporal `Schedule`.

**Zero platform components are added.** Backups, HA, network policy, resource governance,
signing and admission are all already solved for this shape of thing, which is the entire point
of putting the capability here rather than in a vendored chart.

### 4. The panel is a route group on the product origin

`apps/frontend/src/app/(marketing)/marketing/`, served at `<host>/marketing`, `noindex`. This is
the **dev-portal pattern** ([ADR-0009](0009-api-gateway.md), [ADR-0014](0014-frontend.md),
[ADR-0017](0017-url-and-domain-structure.md)) applied unchanged: a route group, not a separate
app; behind the app session; page-gated by the OpenFGA `Checker`, not by a bare session check.

- `proxy.ts` adds `/marketing` to `PROTECTED`, which proves only that *a* session exists.
- The route-group root performs the authoritative check in the RSC layer, exactly as
  `apps/frontend/src/lib/auth/session.ts` already documents for product surfaces.

`infra/auth/openfga/model.fga` gains one type, mirroring the existing ops-tier `dashboard`
shape so there is one pattern rather than two:

```fga
type analytics
  relations
    define viewer: [user, group#member]
    define view: viewer
```

granted via `group:marketing`. This is what resolves the placement problem: marketing never
receives an ops-tier account, never needs AAL2 operator MFA, and never touches Grafana — while
the ops tier's "least authority, not least cookie" rule stays intact.

### 5. Identity, PII and retention are declared up front

Events carry the Faro session ID and, when the visitor is authenticated, the Kratos identity ID.
That makes this table a **PII store by definition**, and it is treated as one from the first
migration: a declared data class with a retention period, schema-level PII tags, reachable by the
right-to-erasure and DSAR workflows, pruned by a retention `Schedule`
([ADR-0023](0023-data-lifecycle-privacy.md)). Raw IP addresses are never stored; user-agent is
reduced to a parsed device class at ingest.

Doing this at design time is most of why the analytics store is a service we own rather than a
vendored product — an erasure workflow cannot reach into a third-party component's schema.

### 6. Session replay is deferred behind a hard trigger

Capture is open source: `@grafana/faro-instrumentation-replay` records via rrweb, and
self-hosted transport through Alloy's `faro.receiver` to Loki/Tempo works. **The player is not.**
Rendering a recorded session is a Grafana Cloud Frontend Observability feature; Grafana OSS has
no documented replay player. Self-hosting replay therefore means either building one
(`rrweb-player` in the existing Next.js app, payloads in the [ADR-0003](0003-cluster-topology.md)
bucket keyed by Faro session ID) or adopting OpenReplay.

Both are real projects, and replay is the worst PII surface in this ADR — it captures the DOM,
which is unbounded by construction. So replay is **deferred, not omitted** (principle 9, no
"temporary"). Trigger: **three distinct incidents within one quarter where a reported bug could
not be reproduced from traces plus RUM logs alone.** On that trigger, the choice is a separate
ADR between building the player and adopting OpenReplay.

### 7. Scale seam: ClickHouse

Postgres as a row store is the floor, not the ceiling claim. The documented Scale swap is
**ClickHouse**, on a measured trigger: **p95 of the marketing panel's funnel query exceeding 2 s
against the declared rollup window, or the events table sustaining more than ~10M rows per
month.** Collection, the routing connector and the panel are unchanged by the swap — only the
service's store and queries move, which is the seam the Collector split buys.

## Consequences

### Positive

- **Zero new platform components.** The Core floor and the 3am operational surface are unchanged.
- **Correlation is free**, because there is one agent and one session identity. No other option
  on the table achieves this without either a second agent or a vendor.
- **Analytics data is under the same privacy discipline as everything else** from the first
  migration, instead of being the one store the erasure workflow cannot reach.
- **Marketing is served without expanding the ops tier**, resolving a gap
  [ADR-0017](0017-url-and-domain-structure.md) did not previously cover.
- **The backend stays swappable** — the browser never learns where events are stored.

### Negative / Risks

- **Marketing gets a panel we build, not exploration they drive.** Every new question is a PR.
  This is the real cost, and it is a people cost rather than a component cost. If the team's
  question rate outgrows the platform team's capacity to answer it, the escape hatch is
  **PostHog Cloud**, not a self-hosted rebuild — and that switch should be made deliberately,
  not drifted into.
- **Faro de-duplicates consecutive identical events.** Click counts will silently undercount
  until emitters are shaped to defeat it. This must be proven by a test, not assumed.
- **Consent is an open legal question.** Faro's session tracker uses web storage, and under
  ePrivacy the *analytics purpose* is generally consent-requiring even though this is
  first-party and carries no advertising cookie. The proposed split — consent gates `marketing.*`
  events only, while ops RUM continues on legitimate-interest grounds — **requires legal
  sign-off and is not the platform team's decision to make.** Until it is signed off, the
  `marketing.*` emitters ship disabled.
- **Funnel SQL is work a free SaaS tier would have given away.** Accepted deliberately in
  exchange for the correlation requirement and zero operational surface.
- **A routing-connector mistake sends identity-bearing events into Loki**, breaching
  [ADR-0011](0011-observability.md). This is a one-line config away at all times and needs a
  standing test, not review vigilance.

## Follow-ups

- `services/analytics/` scaffold from `services/_template/`: event schema, partitioning, rollup
  `Schedule`, OpenAPI spec.
- The data-class registry entry and schema-level PII tags ([ADR-0023](0023-data-lifecycle-privacy.md)),
  plus erasure/DSAR activities for the new store.
- Collector `routing` connector config, and a test asserting no `marketing.*` event reaches Loki.
- `(marketing)` route group, the `PROTECTED` entry in `proxy.ts`, the `analytics` type in
  `model.fga`, and `fga.yaml` assertions covering grant and denial.
- Consent gate in the frontend, and legal sign-off on the purpose split.
- A test proving Faro event de-duplication does not corrupt click counts.
- `docs/operational-surface.md`: add the ClickHouse Scale row with the trigger above.
- `docs/marketing/analytics.md`: the event taxonomy and a funnel/retention query cookbook.

## Rules

- The frontend has exactly one browser telemetry agent (Faro). A second analytics SDK is
  forbidden — it mints a second session identity and breaks error-to-journey correlation.
  `(review-only)`
- Marketing events are emitted via `faro.api.pushEvent` under the reserved `marketing.*`
  namespace and are routed out of the Loki pipeline at the Collector. A `marketing.*` event
  reaching Loki is a defect. `(CI: to be added with the routing connector)`
- Analytics storage is `services/analytics/` on the existing CNPG cluster. A dedicated analytics
  datastore joins the platform only on the documented ClickHouse trigger
  ([`docs/operational-surface.md`](../operational-surface.md)). `(review-only)`
- The marketing panel is a route group on the product origin, page-gated by the OpenFGA
  `Checker` (`analytics#view`) in addition to the `proxy.ts` session gate. Marketing surfaces on
  the ops tier are forbidden. `(review-only)`
- The analytics events table carries a declared data class, schema-level PII tags, and is reached
  by the erasure and DSAR workflows ([ADR-0023](0023-data-lifecycle-privacy.md)). Raw IP
  addresses are never stored. `(review-only)`
- Session replay ships only after the documented incident trigger fires, and via its own ADR.
  `(review-only)`
- `marketing.*` emitters stay disabled until the consent purpose split has legal sign-off.
  `(review-only)`
