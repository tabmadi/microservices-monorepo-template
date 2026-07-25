# ADR-0026: Grafana Dashboard Hierarchy

- **Status:** Accepted
- **Date:** 2026-07-23
- **Deciders:** Platform team
- **Related:** [ADR-0004](0004-gitops.md), [ADR-0011](0011-observability.md), [ADR-0024](0024-kubernetes-debug-ui.md), [ADR-0025](0025-service-map-apm-ui.md)

## Context

[ADR-0025](0025-service-map-apm-ui.md) made the **Applications** dashboard Grafana's
home page. It has since grown into a good *workload directory* — every pod, resource
and RED columns — but a directory is not a health verdict: an operator opening
Grafana during an incident still has to scan a table and infer whether anything is
wrong. Meanwhile the dashboard count is growing (Applications, Service detail,
Platform components, Network: policy denials), and without a stated structure each
new panel invites the two classic failure modes: the single mega-dashboard nobody
can read, and unowned dashboard sprawl.

## Decision drivers

1. **The landing page must answer one question** — "is anything wrong right now, and
   where?" — in seconds, without scanning.
2. **One question per dashboard, one altitude per dashboard.** A panel earns its
   place on a dashboard by answering that dashboard's question; otherwise it moves a
   level down.
3. **Dashboards as code** ([ADR-0004](0004-gitops.md)/[ADR-0011](0011-observability.md)):
   the hierarchy must be visible in `infra/observability/dashboards/`, not in tribal
   knowledge.
4. **Bounded set.** New dashboards need a slot in the hierarchy; ad-hoc questions go
   to Grafana Explore, not a new committed dashboard.

## Decision

Dashboards form a three-level funnel; each level answers one question and links down:

| Level | Dashboard | Question it answers | Default? |
| ----- | --------- | ------------------- | -------- |
| L1 | **Overview** (`overview.json`) | Is anything wrong right now, and where? | **Yes** — Grafana home |
| L1.5 | **Applications** (`applications.json`) | What is running, and how big/busy is each workload? | |
| L2 | **Service detail** (`service-detail.json`) | What symptom does *this* service show? (SLO, RED, resources, logs, traces, profiles) | |
| L3 | **Platform components** (`platform-components.json`) | Is a stateful dependency (Postgres, Temporal) the cause? | |
| L3 | **Network: policy denials** (`hubble-drops.json`) | Is a NetworkPolicy blocking a flow? (history + alert backing) | |

- **Overview is the home dashboard** (`default_home_dashboard_path` in the
  observability values). Its contract: *every panel either turns red or links down a
  level.* Content, in row order: **cluster capacity** (node CPU / memory / disk
  free, CPU and memory requests committed, pod slots used), firing Prometheus
  alerts (count + table, from `ALERTS`), cluster-wide golden signals (total req/s,
  5xx %, p95), per-service SLO table (same expressions as the Service detail SLO
  tiles, rows linking to it), and one-line platform-dependency stats (Postgres,
  Temporal, policy drops) linking to their L3 dashboards. No deep-dive timeseries —
  those live one click down.
- **Capacity sits first, above the alert count**, which is the one deliberate
  departure from "verdict before everything". It earns the position by being the
  only row that is *leading* rather than reporting: running out of disk, memory or
  schedulable capacity is a thing you can still act on beforehand, whereas a firing
  alert is already the incident. It also answers a question the rest of the
  dashboard structurally cannot — every other panel is per-service or
  per-dependency, so a cluster-wide ceiling has no other home. Both ceilings are
  shown because they are different failures: requests-committed predicts "the
  scheduler refuses the next pod", real usage predicts "the kernel kills a
  container", and either can happen while the other looks healthy.
- **Applications stays the workload directory** one click below Overview:
  kubeletstats-driven so idle and non-HTTP pods appear, which the SLO table on
  Overview (HTTP-traffic-driven) deliberately does not guarantee.
- **The triage path is the funnel**: alert fires → Overview says *which*
  service/component → Service detail says *what symptom* → Platform components /
  policy denials / logs / traces say *why*.

## Consequences

- Operators land on a verdict, not a table; the previous landing page is one click
  away and unchanged in role for capacity/"what's running" questions.
- Adding a panel now requires placing it: does it change the L1 verdict, describe
  one service (L2), or one dependency (L3)? Anything that fits none of these is an
  Explore query, not a dashboard change.
- Small dashboards stay small on purpose — policy denials remains its own L3 page
  (evaluated and rejected merging it into Platform components: different question,
  different moment of use) with its always-visible drops stat on Overview instead.
- The e2e dashboard-provisioning test asserts the `overview` uid alongside the
  existing ones.
