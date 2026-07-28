# ADR-0029: API Mocking & the UI Development Loop

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Platform team
- **Related:** [ADR-0000](0000-platform-foundations.md), [ADR-0008](0008-api-contracts.md), [ADR-0009](0009-api-gateway.md), [ADR-0010](0010-auth.md), [ADR-0014](0014-frontend.md), [ADR-0016](0016-environment-parity.md), [ADR-0017](0017-url-and-domain-structure.md), [ADR-0018](0018-testing-strategy.md)

## Context

[ADR-0016](0016-environment-parity.md) defines two local tiers, and a frontend engineer fits
neither. The **inner loop** runs exactly one service natively against dependency stand-ins — but
the frontend is not one service's client. A single panel screen fans out across `/products`,
`/orders`, `/orgs`, and `/charges`, four services the engineer is not changing. The **full
platform** tier serves them, at a cost [ADR-0027](0027-load-and-performance-testing.md) measures
directly: **7.3 GiB peak on one node**, of which roughly 1.3 GiB is the observability stack. None
of that renders a table. At the target scale of ~100 services the gap widens rather than closes,
because the number of services behind a screen grows while the number under change stays one.

Two properties of the platform make the missing tier cheap:

- [ADR-0008](0008-api-contracts.md) emits **exactly the artifact a mock needs**. The
  `gen:openapi-public` projection at `apps/frontend/public/devportal/openapi/internal.json` is one
  merged OpenAPI 3.1 document containing precisely the operations at audience `>= internal` — the
  first-party edge surface, `servers: /api`, with east-west operations and `_template` scaffolding
  filtered out. It is committed and drift-checked by `ci:gen`.
- The **auth stack is small**. Kratos plus Oathkeeper plus the ephemeral Postgres in
  `infra/local/deps.yaml` is a few hundred megabytes — a rounding error against the 7.3 GiB above.

The question this ADR settles is therefore not "how do we simulate the platform" but "which of the
platform's parts are cheap enough to keep real, and which are worth replacing with their contract."

## Decision drivers

In priority order:

1. **The spec is the only source of mock behaviour.** A mock with hand-maintained route files,
   fixture bodies, or a merge script is a second contract that drifts from
   [ADR-0008](0008-api-contracts.md)'s. If a response shape is not derivable from a committed
   OpenAPI artifact, the mock does not serve it.
2. **No development-only code in the application.** Especially not in the authentication path.
   `apps/frontend/src/proxy.ts` is the app's single authn gate; a branch in it that grants a session
   is a production-code risk taken for a development convenience, and
   [ADR-0000](0000-platform-foundations.md) principle 9 predicts what happens to it over time.
3. **The cheapest tier that renders an authenticated page.** The goal is subtractive: remove
   Temporal, OpenFGA, CNPG, the observability stack, and the Go services — not to remove
   everything and rebuild an approximation of it.
4. **Nothing new in any deployed environment.** This is local tooling. It appears in no
   environment, no chart, and no image built from our source.
5. **One way to do things.** [ADR-0014](0014-frontend.md) sanctions MSW. A second mocking
   mechanism is permitted only if it owns a *different* concern, stated explicitly.

## Considered options

The decision splits into two independent questions: **what serves API responses**, and **what
provides identity**. Conflating them is what produces an authentication bypass.

### What serves API responses

- **Prism (Stoplight)** — *chosen.* OpenAPI-native with full 3.1 support, which the specs require.
  Serves committed `examples` when present and generates from schemas when not, so the fidelity
  dial sits in the contract rather than in the tool. Request validation is free feedback: an unknown
  route is a 404, a bad body a 422. Ships as a container, so it enters no `mise` toolchain, no
  `package.json`, and no lockfile.
- **MSW** — sanctioned by [ADR-0014](0014-frontend.md) for unit and component tests, and genuinely
  good there: handlers typed against the generated `openapi-typescript` types make drift a type
  error. Rejected for *this* concern because it is an in-process double, not a running API.
  Intercepting server-component fetches means booting it inside the Next server via an
  instrumentation hook, and nothing outside that one process can reach it. The two mechanisms own
  different layers, which is the justification driver 5 demands.
- **Microcks** — the best GitOps fit of the field and the only option that also does contract
  testing, but it carries MongoDB. A datastore joining the floor to serve a development mock fails
  the budget rule in [`docs/operational-surface.md`](../operational-surface.md) outright.
- **`muonsoft/openapi-mock`** — a Go single binary, so the best language fit and the only option
  needing no container. Rejected as primary on a correctness risk rather than a preference: the
  specs are OpenAPI **3.1**, and its kin-openapi core targets 3.0. It is the documented fallback if
  the vendored container proves unacceptable, gated on demonstrating 3.1 support against the real
  projection.
- **WireMock / Imposter** — best-in-class stateful scenarios, both JVM. Excluded by
  [ADR-0001](0001-language-and-runtime.md).
- **Mockoon** — imports OpenAPI and then owns its own JSON environment file. The import is a fork;
  the spec stops being the source of truth on day two. Rejected on driver 1.
- **Hoverfly** — Go and record/replay, but it needs real traffic to capture before it can serve
  anything. A complement to a real environment, not a substitute for one.
- **Fake services generated from `ogen`** — the highest possible fidelity, including state, since
  they are the real server stubs with in-memory storage behind them. Rejected because the cost is
  *per service*: at ~100 services this is a parallel implementation of the platform.
- **No mock at all** — the honest baseline. Running four demo Go services natively is tractable and
  is what `cluster:lite` is for. It does not survive the target scale, and it does not help an
  engineer who is changing no service at all.

### What provides identity

- **The real Kratos** — *chosen.* See below.
- **A fake IdP** (`mock-oauth2-server`, Dex, a seeded Keycloak) — the standard answer in most
  shops, and it works because OIDC is a *protocol boundary*: any conforming provider is
  interchangeable and the application cannot tell which one answered. Kratos is not that boundary.
  The frontend is coupled to Kratos's own surface — browser self-service flows, flow ids,
  `ui.nodes`, CSRF tokens carried in flow state, opaque session cookies, `/sessions/whoami` — so a
  convincing fake would have to reimplement Kratos's flow state machine. That is a second
  implementation, not a mock, which is why no credible fake Kratos exists. The reasoning is a
  property of Kratos, not a ban on fake IdPs: **Hydra** ([ADR-0010](0010-auth.md)) *is* a protocol
  boundary, so a fake OAuth2 provider is a legitimate option for third-party API client work.
- **An in-application bypass** — rejected on driver 2. It also does not save the work it appears to
  save: a bypass that actually functions must return a fully-populated `Session` (identity id,
  email, roles, AAL) for the [ADR-0010](0010-auth.md) gates downstream of `whoami()`, so a
  hand-maintained fake identity survives anyway — without any of the login, expiry, or cookie
  behaviour that makes keeping Kratos real worthwhile.

## Decision

### The mock serves data. It never serves identity

**The mock has no authentication or authorization responsibilities.** It issues no `401`, is
unaware of sessions, and ignores every credential it receives.

This is not a scoping convenience; there is nothing there to mock. Authentication in this platform
is enforced *outside* OpenAPI — Oathkeeper validates at the edge and injects identity headers
([ADR-0009](0009-api-gateway.md), [ADR-0010](0010-auth.md)) — so no service spec declares a
`securityScheme`. A contract mock derives its behaviour entirely from the spec, and the specs say
every operation is open. Teaching the mock to emit `401`s means hand-authoring auth behaviour in a
second place, which is precisely the drift driver 1 exists to prevent.

The same reasoning disposes of authorization. `GET /orders` returns the caller's orders, filtered
by the identity header in the real service. A mock returning three arbitrary orders is **exactly as
useful** for building the orders table — its columns, empty state, pagination, loading skeleton, and
error state. Ownership correctness is a property of the real service's query; re-deriving it in a
mock teaches nothing and costs maintenance.

### The input is the committed projection, not a runtime aggregate

The mock is served `apps/frontend/public/devportal/openapi/internal.json` and nothing else. It is
the frontend's edge surface by construction, merged into one document, `servers: /api`, and
drift-checked.

**A glob over `services/*/openapi.yaml` is not an acceptable substitute.** It captures
`services/authz/` — an all-`cluster` east-west service whose `servers` is `/` — and
`services/_template/`, which is scaffolding. Aggregating those and stamping `servers: /api` over
the result publishes `/api/identities` and `/api/items` in the mock: routes that do not exist at
the real edge and must not, inverting the audience-to-exposure invariant that
[ADR-0008](0008-api-contracts.md) spends a CI lint (`lint:api-audience`) enforcing. Using the
projection also removes the merge step, its tooling, and its collision-handling entirely.

Consuming a generated artifact is not a weaker source of truth here. Committed generated artifacts
are as canonical as the SDKs the frontend imports ([ADR-0000](0000-platform-foundations.md)
principle 5); if `internal.json` is wrong, `ci:gen` fails.

### Fidelity is bought in the contract, not in the tool

The mock runs **examples-first**: it serves committed `example` / `examples` values from the spec
and falls back to schema generation only where none exist. Schema-generated responses are a
starting point, not the destination — an array schema with no `minItems` legitimately generates an
empty list, and an open object schema generates fields the real API never returns, which makes a UI
built against it unreliable.

The fix belongs in the contract. Examples in `services/<service>/openapi.yaml` make mock responses
**deterministic and code-reviewed**, and the same examples render in the Scalar developer portal
([ADR-0014](0014-frontend.md)) — one investment, two consumers. Schema-generated mode stays
available behind a flag for exploring a new endpoint before its examples exist.

### The `edge` profile

[ADR-0016](0016-environment-parity.md) composes local environments from named profiles. `edge` is
the profile for UI work: **the real edge and the real identity stack, with mocked application
data.**

| Component | State in `edge` | Why |
|---|---|---|
| Traefik | real | routes `/api` to the mock and `/` to the host `next dev`; owns the same-origin contract |
| Kratos | real | login, logout, CSRF, cookie attributes, 7-day expiry, AAL — none of it worth faking |
| Oathkeeper | real | the `401`/`403` behaviour the mock cannot invent |
| Postgres (ephemeral) | real | Kratos's store; the stand-in from `infra/local/deps.yaml` |
| **The mock** | serving `internal.json` | replaces every application service on `/api` |
| Temporal, OpenFGA, CNPG, observability, Go services | absent | none of them renders a page |

The application's authentication path is **byte-identical to production**. There is no bypass, no
development provider, no `NODE_ENV` branch, because nothing needs one.

A second mode needs no profile at all: for landing pages and logged-out surfaces, the mock runs
standalone and the auth stack stays down. That is not a third tier, it is the `edge` profile minus
the part you are not exercising.

### Identity comes from a seeded real login

A real Kratos needs a real identity, provisioned the same way locally and in CI. That bootstrap is
the one [ADR-0018](0018-testing-strategy.md) defines — "a committed deterministic test-identity
bootstrap (an AAL1 product user and an AAL2 operator), provisioned the same way in CI and locally."
The `edge` profile consumes it rather than inventing a parallel development-only identity, and
`scripts/auth-token.sh` performs the login by driving the real native login flow.

Day to day this is close to free. Kratos sessions have a **7-day lifespan**
(`infra/auth/kratos/values.yaml`), so a human logs in roughly once a week; the bootstrap exists so a
freshly-created cluster is usable immediately and so CI never types a password.

### The mock is not a platform component

It joins no tier in [`docs/operational-surface.md`](../operational-surface.md). That inventory
governs software the platform *operates* in an environment, and this runs only on an engineer's
machine — the same status `k6` holds under [ADR-0027](0027-load-and-performance-testing.md). The
omission is a decision, not an oversight.

### The mock is forbidden anywhere correctness is asserted

[ADR-0018](0018-testing-strategy.md) driver 4 — "no mocks in acceptance" — extends to this mock
without exception. It never appears in `mise run test`, `ci:affected`, the e2e or visual suites, or
any deployed environment. Its only consumer is a human looking at a browser.

The mock tool's validating-proxy mode — sitting in front of a real backend to check live traffic
against the spec — is not used either, because the platform already answers that question twice
over: the server is generated from the spec by `ogen`, and every generated Go client validates
responses against it (`oas_response_decoders_gen.go`), so a spec-violating service response fails
the service integration tests that drive it through that client. What escapes both is the edge's own
error responses (`401`/`403`/`429` from Traefik and Oathkeeper), which reach no generated client;
that fixed, small set is asserted against the Problem envelope in e2e rather than by standing up a
proxy.

## Consequences

### Positive

- The frontend has a development tier that costs a fraction of `cluster:full` while leaving the
  authentication path untouched.
- No development-only code ships in `apps/frontend/`. The class of bug where a screen works locally
  and `403`s in staging cannot occur, because the local gates are the real gates.
- The mock cannot drift from the contract: its only input is a CI-drift-checked artifact.
- Examples in the specs serve the developer portal and the mock simultaneously.
- The test-identity bootstrap has two consumers, so it is exercised daily rather than only nightly.

### Negative / Risks

- **A third vendored Node tool.** Prism's image is third-party Node software the repo runs but does
  not author, alongside the Playwright runner and the Lowdefy console
  ([ADR-0001](0001-language-and-runtime.md)). Scope is hard: a local-only container, no Node in any
  `.mise.toml`, no `package.json`, no lockfile, never in an image built from our source. The
  `lint:node-scope` invariant that npm exists only in `e2e/` is unaffected.
- **The mock is stateless.** A create followed by a read does not reflect the write, and a
  `WorkflowHandle`'s `result_url` polls nothing. This is the honest boundary of the tier: persistence
  and Temporal behaviour require real services, and pretending otherwise is what makes mocks lie.
- **Examples are a maintenance surface.** A schema change with a stale example is drift the vacuum
  ruleset does not catch on its own. Mitigated by keeping examples minimal and by the follow-up lint
  below.
- **The `edge` profile is heavier than a bare container.** Traefik, Kratos, Oathkeeper, and Postgres
  must be up to render an authenticated page. Accepted deliberately: that cost is what buys the
  absence of every development-only auth branch.
- **Two mocking mechanisms exist.** MSW at the test layer, Prism at the dev-loop layer. Mitigated by
  the layer boundary being explicit and by neither being permitted in e2e.

### Follow-ups

- `infra/local/mock.yaml` — the mock Deployment, Service, and the `/api` IngressRoute; the path the
  mock receives must match the paths declared in the projection (a `stripPrefix` middleware
  mirroring `strip-auth` if the tool does not honour the document's base path).
- The `edge` profile as an [ADR-0016](0016-environment-parity.md) values overlay, plus the
  `cluster:edge-profile` task and `mock:start` / `mock:stop` / `mock:logs` for the standalone mode.
- The committed test-identity bootstrap from [ADR-0018](0018-testing-strategy.md), consumed by both
  `edge` and the e2e setup project.
- `example` / `examples` on every response schema in `services/*/openapi.yaml`, starting with the
  list endpoints whose unconstrained arrays generate empty responses.
- A vacuum ruleset rule requiring an `example` on every `2xx` response schema, so the mock's
  fidelity is enforced rather than hoped for.
- `docs/dev-loop.md` — the UI development section: which mode to pick, how to log in, and what the
  tier deliberately cannot tell you.

## Rules

- API mocking exists for the UI development loop only. The mock appears in no deployed environment, no chart, and no image built from our own source. `(review-only)`
- The mock's only input is the committed `internal.json` projection from `mise run gen:openapi-public`. Globbing `services/*/openapi.yaml`, hand-written route files, and standalone fixture bodies are forbidden — a mocked response shape that is not derivable from a committed OpenAPI artifact is a defect. `(review-only)`
- The mock serves no authentication or authorization behaviour: no `401`, no session awareness, no identity headers. Auth is enforced at the edge and is absent from the specs by design ([ADR-0009](0009-api-gateway.md), [ADR-0010](0010-auth.md)). `(review-only)`
- The application contains no development-only authentication code. A session bypass, a fake session object, or a `NODE_ENV`-conditional branch in `apps/frontend/src/proxy.ts` or `src/lib/auth/` is a review-blocker. `(CI: lint:auth-inline)`
- Authenticated local development uses the real Kratos in the `edge` profile with the committed test identity from [ADR-0018](0018-testing-strategy.md). Fake identity providers are not used for Kratos; they remain permitted for Hydra, which is a protocol boundary. `(review-only)`
- The mock runs examples-first, serving committed `example` / `examples` from the spec. Schema-generated responses are a flag-gated fallback for endpoints whose examples do not yet exist. `(review-only)`
- The mock is forbidden in `mise run test`, `ci:affected`, and the e2e and visual suites, which run against real services ([ADR-0018](0018-testing-strategy.md)). `(review-only)`
- The mock ships as a vendored container. It pins no Node in any `.mise.toml` and adds no `package.json`, lockfile, or `node_modules` to the repo. `(CI: lint:node-scope)`
- The mock is local tooling and joins no tier in [`docs/operational-surface.md`](../operational-surface.md). `(review-only)`
- Statelessness is the tier's boundary: persistence, workflow progression, and authorization decisions are exercised against real services, never asserted against the mock. `(review-only)`
