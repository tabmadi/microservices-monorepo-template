# ADR-0018: Testing Strategy & End-to-End

- **Status:** Accepted
- **Date:** 2026-07-26
- **Deciders:** Platform team
- **Related:** [ADR-0001](0001-language-and-runtime.md), [ADR-0002](0002-monorepo.md), [ADR-0008](0008-api-contracts.md), [ADR-0014](0014-frontend.md), [ADR-0016](0016-environment-parity.md), [ADR-0017](0017-url-and-domain-structure.md), [ADR-0027](0027-load-and-performance-testing.md)

## Context

Earlier ADRs pin pieces of testing but never the whole: ADR-0002 gives the `test` /
`ci:test` task names and affected-detection; ADR-0014 covers frontend unit/component
(`bun test`) and named Playwright for frontend e2e; ADR-0016 names the `cluster:full`
tier as the thing e2e *runs on*; ADR-0010 has its own authz conformance suite. Nothing
owns the cross-cutting question: **what is our acceptance test for "the platform works",
where does it live, what drives it, and when does it run.**

This ADR fixes that. It defines the test pyramid once, pins the **end-to-end and visual
layer**, and reconciles cadence with affected-detection ([ADR-0002](0002-monorepo.md)) and
the full-platform tier ([ADR-0016](0016-environment-parity.md)).

**Scope note (2026-07-26).** Every layer below answers *is it correct*, at a load of
roughly one user. *What does it cost, and where does it break* is a different question with
a different tool, cadence and failure meaning; it is owned by
[ADR-0027](0027-load-and-performance-testing.md) and is deliberately not part of this
pyramid, `mise run test`, or the e2e suites.

## Decision drivers

In priority order:

1. **The rendered, authenticated UI is the ultimate guarantee.** A working dashboard
   (Grafana, Hubble UI, Temporal) behind a real session proves the whole stack underneath —
   edge, auth, services, data — is wired correctly. Browser acceptance is the gauge; cheaper
   checks exist only to localise a failure faster.
2. **One tool, one way** ([ADR-0000](0000-platform-foundations.md)). The same engine drives
   product journeys, operator dashboards, and visual regression.
3. **Cost is the bring-up, not the test.** Every full-platform e2e shares one expensive
   prerequisite — a running `cluster:full`. Cadence is set per environment so one bring-up is
   amortised across every suite that needs it.
4. **No mocks in acceptance.** E2e runs against real services; mocking defeats the purpose.
5. **Per-service cost.** At the target scale, automatic full-platform bring-up on every PR
   does not survive; the heavy suite must be gated.

## Considered options

### Browser/e2e/visual engine

- **Playwright (TypeScript)** — *chosen.* Out-of-process driver crosses origins natively
  (the Kratos redirect + `*.ops.<host>` subdomains of [ADR-0017](0017-url-and-domain-structure.md)),
  lowest-flake auto-waiting for heavy SPA dashboards, and a built-in visual-comparison
  assertion (`toHaveScreenshot`). Its runner is Node — see the runtime note below.
- **WebdriverIO** — the only other serious all-rounder (BiDi cross-origin, a visual service,
  Appium native-mobile). Rejected: higher baseline flakiness and bolt-on visual hit exactly
  where we are most sensitive (heavy dashboards, visual regression), and its one decisive edge
  — native mobile — is unused on a web platform. Also Node-based, so it buys back no purity.
- **Cypress** — good component + visual story, but single-browser-context architecture fights
  cross-origin navigation and multi-tab; our auth-redirect + ops-subdomain topology is its weak
  spot. Rejected.
- **Pure-Go browser libs (Rod / chromedp)** — the only genuinely Node-free path. Rejected: no
  visual-regression framework (we would hand-roll pixel diffing, baselines, and a review flow)
  and raw-CDP auto-wait is weaker on heavy dashboards — the two things we need most.
- **AI/agent tools (Stagehand, Midscene, Shortest, …)** — built *on* Playwright/CDP or
  LLM-in-the-loop nondeterministic and vendor/cloud-tilted. Wrong fit for a deterministic,
  self-hosted, config-as-files CI gate; they wrap an engine we must still choose.

### Runtime for the Playwright runner

Bun is the sole JS runtime ([ADR-0001](0001-language-and-runtime.md)), but Bun **cannot
reliably run a browser test runner**: Playwright (and every Node browser runner) spawns the
browser with extra file descriptors (fd 3/4) as a pipe transport, and forks workers over Node
IPC — the least-traveled corners of `child_process` that Bun has not fully matched (browser
launch hangs/segfaults; the runner produces no output). This is a Node-ecosystem-wide gap, not
a Playwright bug, and not a "temporary" we may build on ([ADR-0000](0000-platform-foundations.md) §9).
We therefore **sanction Node as a test-only escape hatch** ([ADR-0001](0001-language-and-runtime.md)),
scoped to the e2e/visual runner alone.

## Decision

### The pyramid — three concerns, one acceptance gauge

| Layer | Tool | Environment | Role |
|-------|------|-------------|------|
| **Unit / component** | `go test`, `bun test` ([ADR-0014](0014-frontend.md)) | none / `happy-dom` | logic & component shape in isolation |
| **Service integration** | `go test` + generated SDK clients ([ADR-0008](0008-api-contracts.md)) | `cluster:lite` (deps only) | a service against real Postgres/Temporal/OpenFGA |
| **Preflight readiness** | Go / shell | `cluster:full` | fast failure **localiser** — pods ready, ports open, Postgres/Oathkeeper reachable; runs before the browser suite so a red e2e instantly reads "infra down" vs "app broken" |
| **Browser acceptance e2e** | **Playwright (TS)** | `cluster:full` | **the gauge** — product journeys + operator dashboards rendered behind a real AAL2 session |
| **Visual regression** | **Playwright `toHaveScreenshot`** | `cluster:full` / static render | component shape vs committed baselines |

Preflight readiness is **not** a competing acceptance test — it is triage that points at the
failure faster. The browser test is always the final word.

### Layout

All e2e and visual tests live in a single repo-root **`e2e/`** Playwright workspace (one config,
one runner):

- `e2e/platform/` — cross-service product journeys (register → catalog → order → pay) and the
  operator-dashboard journeys (Grafana, Hubble UI, Temporal, MinIO rendered behind an AAL2 session
  per [ADR-0017](0017-url-and-domain-structure.md)).
- `e2e/frontend/(landing|panel|devportal)/` — per-route-group frontend feature suites.
- `e2e/visual/` — component visual regression against committed baselines.

### Cadence

| Suite | Trigger | Contents |
|-------|---------|----------|
| Unit / component / integration | **per-PR**, affected-scoped ([ADR-0002](0002-monorepo.md)) | `go test`, `bun test`, deps-only integration |
| **Smoke** (`mise run e2e:smoke`) | **per-PR, label-gated** | one product golden path + a key dashboard render, against `cluster:full` |
| **Full** (`mise run e2e`) | **nightly + pre-release** ([ADR-0013](0013-release-and-versioning.md)) | every product journey, every operator dashboard, all visual baselines |

Affected-detection ([ADR-0002](0002-monorepo.md)) scopes the cheap per-PR layers; the
full-platform suites are their own CI jobs, not part of `ci:affected`, because every e2e crosses
service boundaries by nature. Automatic full-platform bring-up on every PR does not survive the
target scale, so smoke is **opt-in via a PR label** for risky changes.

### Test data

Kratos starts with an empty identity store and no seeded user, and the local SMTP sink is not
wired ([dev-loop](../dev-loop.md)). E2e therefore ships a **committed deterministic test-identity
bootstrap** (an AAL1 product user and an AAL2 operator), provisioned the same way in CI and
locally — the same throwaway-credential pattern SOPS already uses for the local age key
([ADR-0016](0016-environment-parity.md)). No test depends on hand-created state. The same bootstrap
provisions the identity the `edge` development profile logs in as
([ADR-0029](0029-api-mocking-and-ui-dev-loop.md)), so it is exercised daily rather than only by the
nightly suite.

### Visual baselines and Figma

The CI gate is **committed accepted-snapshot diffing** (`toHaveScreenshot` against baselines in
`e2e/visual/`); an intentional UI change updates the baseline in the same PR. **Figma stays the
authoring source of truth** ([ADR-0014](0014-frontend.md)) reviewed by humans, not an automated
CI pixel-diff — rendered-vs-Figma diffing is too brittle (font hinting, anti-aliasing) to gate
on. Component-isolation tooling (Storybook) and a hosted review UI (Argos) are deferred behind a
measurable trigger: adopt when built-in baseline diffing no longer scales.

## Consequences

### Positive

- The platform has one acceptance gauge — a rendered, authenticated UI — and one tool driving it.
- Operator dashboards are first-class tests: a green run proves edge + auth + services + data end to end.
- One bring-up amortised across every full-platform suite keeps the heavy tier affordable.
- Frontend, cross-service, and ops e2e share a single Playwright config and CI job shape.

### Negative / Risks

- **Node returns** as a sanctioned runtime. Mitigated by hard scoping ([ADR-0001](0001-language-and-runtime.md)):
  for testing it appears only in the `e2e/` runner and CI, never in a service, app/lib code, or an
  image built from our own source. It is pinned in `e2e/.mise.toml`, not the root toolchain, so it
  installs only for a dev who runs the suite. Frontend dev and unit tests stay on Bun. (ADR-0001
  sanctions one other Node island for the same vendored-tool reason: the Lowdefy admin console,
  [ADR-0012](0012-internal-admin.md).)
- **Label-gated smoke means an unlabeled PR gets no full-platform signal until nightly**, so an
  edge/auth/cross-service break can sit in `master` up to ~24h. Accepted as the cost of not paying
  a full bring-up per PR; the mitigation is to label risky PRs.
- **Operator-dashboard e2e lives only in the nightly full suite**, so platform-contract
  regressions there surface within 24h, not per-merge. Accepted.
- **Heavy SPA dashboards can be flaky.** Mitigated by Playwright auto-wait and the preflight
  readiness gate isolating infra failures from app failures.

### Follow-ups

- `e2e/` Playwright workspace: `playwright.config.ts`, `e2e/platform/`, `e2e/frontend/`, `e2e/visual/`.
- Node pinned in `.mise.toml` as a test-only tool; `@playwright/test` + browser binaries install.
- Root tasks `e2e` and `e2e:smoke` ([ADR-0002](0002-monorepo.md)); `e2e.yml` (nightly + pre-release) and the label-gated smoke job in CI.
- Go/shell preflight readiness checks under `e2e/preflight/`.
- Committed test-identity bootstrap (AAL1 user + AAL2 operator) wired into the e2e setup project.
- The shop-demo golden-path smoke (register → catalog → order → pay) + one dashboard render.

## Rules

- Playwright (TypeScript) is the only browser e2e and visual-regression tool. Cypress, WebdriverIO, Selenium, and pure-Go browser libraries are not used.
- All e2e and visual tests live in the repo-root `e2e/` workspace under one Playwright config.
- The browser acceptance test is the platform's acceptance gauge; operator dashboards (Grafana, Hubble UI, Temporal, MinIO) are tested rendered behind a real AAL2 session, not by HTTP status alone.
- Preflight readiness checks (Go/shell) run before the browser suite as failure localisers; they are not acceptance tests.
- E2e runs against `cluster:full` with real services. MSW and all mocking are forbidden in e2e ([ADR-0014](0014-frontend.md)) — including the development API mock and the `edge` profile it runs in ([ADR-0029](0029-api-mocking-and-ui-dev-loop.md)), whose only consumer is a human looking at a browser.
- Service integration tests run against `cluster:lite` deps and drive services through their generated SDK clients ([ADR-0008](0008-api-contracts.md)); they do not import another service's code.
- The full e2e + visual suite runs nightly and pre-release. The smoke suite runs per-PR only when labeled. Neither is part of `ci:affected`.
- Visual regression gates on committed `toHaveScreenshot` baselines; an intentional UI change updates the baseline in the same PR. Automated rendered-vs-Figma diffing is not a CI gate.
- E2e provisions a committed deterministic test identity (AAL1 user + AAL2 operator); no test relies on hand-created state.
- Within testing, Node is permitted solely as the Playwright e2e/visual runner ([ADR-0001](0001-language-and-runtime.md)); it appears in no service, app/library code, or image built from our own source. It is pinned in `e2e/.mise.toml` against the root `[env] NODE_VERSION`, never in the root toolchain.
