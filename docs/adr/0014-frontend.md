# ADR-0014: Frontend Stack & Conventions

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Platform team
- **Related:** [ADR-0001](0001-language-and-runtime.md), [ADR-0002](0002-monorepo.md), [ADR-0008](0008-api-contracts.md), [ADR-0009](0009-api-gateway.md), [ADR-0010](0010-auth.md), [ADR-0011](0011-observability.md)

## Context

The single Next.js app under `apps/frontend/` is the front door for landing pages, the authenticated product panel, an internal admin entry point, and the developer portal — all as route groups ([ADR-0002](0002-monorepo.md)). Earlier ADRs pin language, runtime, deployment, codegen, and auth integration. They do not pin how the app is built day-to-day: rendering model, data fetching shape, styling system, forms, lint, testing, browser-side observability, performance gates.

This ADR is the single entry point for a newcomer working on the frontend.

### Pinned by earlier ADRs (not relitigated)

| Concern                   | Decision                                                                                      | ADR                                                            |
|---------------------------|-----------------------------------------------------------------------------------------------|----------------------------------------------------------------|
| Framework                 | Next.js, single app, route groups `(landing\|panel\|devportal)`                        | [0001](0001-language-and-runtime.md), [0002](0002-monorepo.md) |
| Language + runtime        | TypeScript, Bun as the only JS runtime (no Node anywhere)                                     | [0001](0001-language-and-runtime.md)                           |
| Workspaces                | Bun workspaces, no Turborepo                                                                  | [0002](0002-monorepo.md)                                       |
| API clients               | Generated via `openapi-typescript` + `openapi-fetch` from per-service `openapi.yaml`          | [0008](0008-api-contracts.md)                                  |
| Login UI                  | Custom Next.js driving Kratos self-service flows in `(landing)/auth/`                         | [0010](0010-auth.md)                                           |
| Developer portal          | Route group, not a separate app                                                               | [0009](0009-api-gateway.md)                                    |
| Container                 | Next.js standalone output, tagged `frontend:<git-sha>`, deployed via the shared service chart | [0002](0002-monorepo.md), [0004](0004-gitops.md)               |
| Cross-route-group imports | Lint-forbidden                                                                                | [0002](0002-monorepo.md)                                       |

This ADR adds the remaining first-party choices.

## Decision drivers

1. **One stack for every route group.** Landing, panel, admin, and devportal share the same primitives.
2. **RSC-first.** Use Server Components and the generated SDK on the server where possible; ship the smallest possible client bundle.
3. **Figma-shaped.** The design system is the contract with design; the codebase reflects Figma tokens, not the other way around.
4. **Per-app cost matters.** Adding a route group or a new SDK consumer must not require a per-consumer toolchain decision.
5. **Boring defaults, strict gates.** Strong defaults make a small team productive; CI catches regressions.

## Considered options

- **Pages Router** — App Router is stable and fits the server-heavy, small-client-bundle goal. Pages Router does not.
- **CSS Modules / CSS-in-JS** — viable, but Untitled UI's design contract is in Tailwind tokens; mixing two systems doubles design-system surface.
- **shadcn/ui as the primitives source** — strong contender; rejected because Untitled UI's Figma compatibility is the load-bearing requirement. Untitled UI tokens *could* layer onto shadcn primitives later if a specific primitive is missing.
- **TanStack Router / Remix / Astro** — Next.js is pinned by [ADR-0001](0001-language-and-runtime.md), [ADR-0002](0002-monorepo.md).
- **Biome + minimal ESLint for `@next/eslint-plugin-next`** — second-best. Rejected to keep one tool; the Next-specific rules we care about are caught by `next build`, by Lighthouse-CI, and by typed `next/image` + `next/font` APIs.
- **Vitest / Jest for unit tests** — Bun ships a Jest-compatible test runner; pulling in a second runner duplicates what the platform's only JS runtime already provides.
- **next-intl day one** — premature without a locale on the roadmap; deferred behind a trigger.
- **Vercel `flags`** — Vercel-runtime-specific; rejected for an in-cluster Bun runtime.
- **Storybook** — useful but not load-bearing for a 3–8 person team with one app where Figma is already the isolated visual catalog. Deferred; component tests cover behaviour and a single in-repo "kitchen sink" page (see below) covers visual sanity. Re-evaluated if a second frontend app lands or a dedicated design-system maintainer joins.

## Decisions

### Rendering: App Router, Server Components default

Components are server components by default; `"use client"` is added only at the smallest necessary interactivity boundary. Server Actions are permitted for form submission against the route group's owning service; cross-service mutations go through the service's REST API and use the workflow-handle pattern from [ADR-0006](0006-temporal.md).

Every route segment ships `loading.tsx` and `error.tsx`. Every route-group root additionally ships `not-found.tsx`. A lint rule enforces presence.

### Data fetching

- **Server components** fetch via the generated SDKs in `libs/ts/sdks/<service>/`. An app-local `src/lib/server-fetch/server.ts` wraps `openapi-fetch` with a server-only fetcher (marked `import "server-only"`) that forwards the Kratos session cookie and W3C trace context. Direct `fetch` to service URLs is forbidden. The `server-fetch` directory has no barrel: client code imports `server-fetch/client`, server code imports `server-fetch/server`, so server-only modules never leak into a client bundle.
- **Client components** use TanStack Query wrapping the same SDKs via `src/lib/server-fetch/client.ts`. Query keys derive from `operationId`.
- **Mutations** prefer Server Actions when single-service. Cross-service flows return a `202 Accepted` workflow handle ([ADR-0006](0006-temporal.md)) and the client polls via the workflow-handle helper.

### Styling: Tailwind v4 + Untitled UI, CSS-first

We follow Untitled UI's Next.js integration exactly, so a component copied from untitledui.com drops in unmodified.

- Tailwind CSS v4 is the styling system, wired CSS-first (no `tailwind.config.js`). CSS Modules and CSS-in-JS are forbidden in app code; the only exception is third-party components that ship their own styles.
- Design tokens are Untitled UI's committed token file at `src/styles/theme.css` (full brand/gray/error/warning/success palettes, semantic text/bg/border/fg/utility colors, typography, radius, shadows, animations), imported by `src/styles/globals.css` together with `src/styles/typography.css`. There is no JS token mirror; TS consumers that need a raw value read the CSS variable. Token edits are PRs; upstream Untitled UI bumps are tracked in `src/components/UPSTREAM.md` with a yearly bump cadence.
- `globals.css` registers the plugins Untitled's primitives depend on — `tailwindcss-react-aria-components` (React Aria state variants) and `tailwindcss-animate` — and declares Untitled's custom variants (`dark`, `label`, `focus-input-within`).
- Class composition uses Untitled's `cx` + `sortCx` from `src/utils/cx.ts` (a `tailwind-merge` wrapper). Hand-written `cn()` helpers are not added.
- Dark mode via `next-themes`, which writes Untitled's `.dark-mode` class on the root element; the `dark` custom variant keys off it.

### Code layout: one app, no first-party packages

There is exactly one consumer of the frontend code — the `apps/frontend/` app. Route groups (`landing|panel|devportal`) are folders within that one app, one bundle, one `node_modules`; they are **not** independent build targets. A workspace package only earns its keep when there is a **second independent consumer** (a second app, a published design system) or when the code is a **generated / independently-versioned artifact**. Splitting single-consumer code into `libs/ts/*` packages buys nothing and costs real ceremony: per-package `dependencies`, `peerDependencies` to keep a single React instance, `transpilePackages`, and path-alias wiring — and under Bun's isolated linker that ceremony is load-bearing, so a missing entry is a build break rather than a lint nit.

**Principle:** extract a TS package only on a second consumer or for generated artifacts. Until then, first-party frontend code lives inside the app.

Applying it, first-party code lives under `apps/frontend/src/`:

| Code                       | Location                                                                                                     |
|----------------------------|--------------------------------------------------------------------------------------------------------------|
| UI primitives              | `src/components/{base,application,foundations}/` (Untitled UI layout)                                        |
| Design tokens              | `src/styles/theme.css`, `src/styles/typography.css`                                                          |
| `cx()` / `sortCx()` + helpers | `src/utils/cx.ts`, `src/utils/is-react-component.ts`                                                      |
| Server/client fetchers     | `src/lib/server-fetch/`                                                                                      |
| Browser + server telemetry | `src/lib/observability/`                                                                                     |
| Feature flags              | `src/lib/feature-flags.ts`                                                                                   |
| User-facing strings        | `src/strings/<route-group>.ts`                                                                               |
| Generated API SDKs         | `libs/ts/sdks/<service>/` (the **only** `libs/ts` member — generated from OpenAPI, plausibly multi-consumer) |

### Component library: `src/components/{base,application,foundations}/`

Primitives live under `src/components/` in Untitled UI's own layout — `base/` (Button, Input, Badge, Toggle…), `application/` (Table, Modal, Navigation…), and `foundations/` (icons, logos). Route groups compose them via their explicit `@/components/base/...` paths; they do not duplicate them. Untitled UI React ships source you own, built on [React Aria Components](https://react-spectrum.adobe.com/react-aria/) for accessibility; the components are vendored into the repo as committed source — not runtime-fetched. Keeping upstream's folder layout and utility names (`cx`, `sortCx`) verbatim is deliberate: it makes adding a component (`npx untitledui@latest add <component>`) or a yearly bump a clean diff rather than a rewrite. Upstream bumps are tracked in `src/components/UPSTREAM.md`.

Heuristic: if two route groups would copy a component, it belongs under `src/components/`.

Icons are `@untitledui/icons` (Untitled UI's own icon set), passed to primitives as components (e.g. `iconLeading={Plus}`).

**Kitchen-sink page.** `apps/frontend/src/app/(devportal)/devportal/kitchen-sink/page.tsx` renders every primitive under `src/components/` once. It is the cheap alternative to Storybook: one route, no separate toolchain, gated by the (devportal) Kratos session. Every primitive added under `src/components/` gets a `<Section>` there in the same PR.

### Developer portal renderer: Scalar

The `(devportal)` route group renders the OpenAPI specs through **Scalar** (`@scalar/api-reference-react`), an MIT-licensed
renderer chosen for the one feature the URL layout depends on — a **built-in, free request console** that, being same-origin
with `/api` ([ADR-0017](0017-url-and-domain-structure.md)), lets "try it" call the real edge with the caller's session and
no CORS. It is embedded as a `"use client"` island in the route group, never a separate service ([ADR-0009](0009-api-gateway.md)).

- **The spec it renders is a pre-filtered projection, not the raw specs.** `mise run gen:openapi-public` merges the service
  specs into one document per projection and filters on the `x-audience` ladder ([ADR-0008](0008-api-contracts.md)): the
  dev portal keeps operations at audience `>= internal`, the public bundle keeps only `public`, and `cluster` (east-west)
  ops appear in neither. Audience scoping stays ours, so the renderer only ever sees what its audience may see — the strip
  is real, not a UI hide.
- **Self-hosted, no CDN.** The npm package is bundled by `next build` (not a `<script>` tag), and default web fonts are
  disabled (`withDefaultFonts: false`) so nothing is fetched at runtime — matching the offline/proxied bring-up the rest of
  the platform assumes.
- **CSP fit** ([Content Security Policy](#content-security-policy)): Scalar injects inline styles (covered by `style-src`),
  self-hosts its fonts (`font-src 'self'`), and its console fetches same-origin `/api` (covered by `connect-src 'self'`).
- **A deliberate visual island.** Scalar ships its own theme; the portal does not reuse Untitled UI primitives. Accepted for
  one route group — matching a spec renderer to the design system is not worth the maintenance, and the console is worth more
  than pixel parity. Redoc (console paywalled) and a docs platform (Fern/Mintlify — a separate service, duplicates the SDK
  codegen) were rejected on the ADR-0009 grounds; Stoplight Elements is the fallback if Scalar's churn bites.

### Forms

- `react-hook-form` for state and validation orchestration.
- `zod` for schemas. Schemas for OpenAPI operations are generated from the spec under `tools/codegen/zod-gen/` and committed at `libs/ts/sdks/<service>/schemas/`. The `mise run gen:zod` task is included in `mise run gen` and drift-checked by `ci-drift.yml`.
- A single `<Form>` primitive under `src/components/base/` wires react-hook-form + zod + the design-system inputs. Hand-rolled form wiring is a review-blocker.

### Client state

- URL state for filters, pagination, tab selection: **`nuqs`**.
- RSC + URL state covers most cases. For genuine client-only state outliving a component tree, use **Zustand** stores under `apps/frontend/src/stores/`. Redux and MobX are forbidden.
- React Context is for theming and per-route-group session bootstrapping only — not cross-cutting state.

### Auth wiring

- The Next.js proxy (`src/proxy.ts`, the Next 16 successor to `middleware.ts`) checks the Kratos session on every request under `(panel)`, `(devportal)`. `(landing)` is public except for its `auth/` subtree (Kratos flows).
- The proxy reads the Kratos session cookie and forwards a session-id header to server components via `headers()`. Server components never call Kratos directly.
- The frontend never mints, decodes, or validates JWTs. Service calls from server components attach the user's Kratos cookie; Oathkeeper validates it at the edge and injects identity headers ([ADR-0009](0009-api-gateway.md), [ADR-0010](0010-auth.md)).

### Content Security Policy

CSP is a frontend responsibility because a strong policy needs a per-request nonce.

- **Nonce in `src/proxy.ts`.** The proxy generates a random nonce per request, sets it on the request header and in the `Content-Security-Policy` response header (`script-src 'nonce-<x>' 'strict-dynamic'`; `object-src 'none'`; `base-uri 'self'`). Next.js propagates the nonce to its own scripts automatically. Unsafe-inline scripts are forbidden.
- **`connect-src` allowlists first-party telemetry.** The OTel-web and Faro exporters POST to the Traefik-fronted ingest route; `'self'` covers it when same-origin, otherwise the ingest origin is listed explicitly. A missing entry silently breaks browser RUM, so the kitchen-sink page exercises it.
- **Static hardening is duplicated at the edge** as defense-in-depth: the non-nonce directives that never vary (`frame-ancestors 'none'`, `X-Content-Type-Options: nosniff`, `Referrer-Policy`, HSTS) are set by a Traefik `Middleware` ([ADR-0009](0009-api-gateway.md)) so every route gets them, not just Next pages.

### CSRF

CSRF protection applies to cookie-authenticated state changes (the Kratos session cookie). Bearer-token traffic (Hydra/Oathkeeper) is not browser-attached and is not CSRF-exposed.

- **SameSite cookies.** The Kratos session cookie is `SameSite=Lax` + `Secure` + `HttpOnly` (set in `infra/auth/kratos/`, [ADR-0010](0010-auth.md)). This alone blocks the classic cross-site POST.
- **Kratos self-service flows** carry Kratos's built-in anti-CSRF cookie + token; the custom login UI drives those flows and must not disable it.
- **Server Actions** (the single-service mutation path) rely on Next.js's built-in `Origin`/`Host` check, with `serverActions.allowedOrigins` pinned in `next.config`. Hand-rolled CSRF tokens are not added on top.
- **Other cookie-authenticated mutations** are rejected at the edge by an Origin-allowlist rule ([ADR-0009](0009-api-gateway.md)) for state-changing methods.

### Lint and format: Biome only

Biome is the single lint+format tool for the frontend.

- Configured in `biome.jsonc` at the repo root with the `recommended` and `correctness` rule sets at error level, plus the strict additions: `noExplicitAny`, `noNonNullAssertion`, `useExhaustiveDependencies`, `useImportType`, `noUnusedImports`, `noUnusedVariables`, `useAwait`, `noFloatingPromises`, `noConsole` (server uses `pino`; client uses the OTel-aware logger from `src/lib/observability/`).
- `biome ci` runs in `lint.yml`; `biome format --write` is a lefthook pre-commit hook.
- **ESLint is not installed.** Next-specific concerns are caught by `next build` + Lighthouse-CI + typed `next/image` / `next/font` APIs.

### Testing

- **`bun test`** for unit and component tests — Bun's built-in Jest-compatible runner. No Vitest, no Jest: Bun is the only JS runtime ([ADR-0001](0001-language-and-runtime.md)), and shipping a third-party runner duplicates what's already in the toolchain. Component tests use Testing Library with `happy-dom` registered via `bunfig.toml` `preload`.
- **End-to-end and visual-regression tests are owned by [ADR-0018](0018-testing-strategy.md):** Playwright drives them from the repo-root `e2e/` workspace (frontend route-group suites under `e2e/frontend/(landing|panel|devportal)/`, visual baselines under `e2e/visual/`), running against `cluster:full`. They are not part of this app's `bun test` runner.
- **MSW** for mocking SDK calls in unit/component tests — an in-process double, scoped to the test runner. MSW is forbidden in e2e: e2e runs against real services ([ADR-0018](0018-testing-strategy.md)). The separate concern of a *running* mock API for the development loop is owned by [ADR-0029](0029-api-mocking-and-ui-dev-loop.md); the two are different layers and neither is permitted in e2e.
- Coverage thresholds per route group in `bunfig.toml`; CI fails below threshold.

### Observability

The browser side of [ADR-0011](0011-observability.md) is wired here.

- `@opentelemetry/sdk-trace-web` + `@opentelemetry/instrumentation-fetch` live in `src/lib/observability/client.ts` and are initialised from a client-only entry at `apps/frontend/src/app/observability-init.tsx`. Trace IDs propagate via `traceparent` on outbound fetches, joining the same trace as the upstream services.
- **Grafana Faro** is the browser RUM agent. Web Vitals (LCP, INP, CLS), JS errors, and session traces forward through a Traefik-fronted ingest route (`/api/rum`, a vendor-neutral path) to the OTel Collector's `faro` receiver ([ADR-0011](0011-observability.md)), landing in the same Loki/Tempo backends as services. Locally, where `next dev` runs on the host with no edge, a dev-only route handler shims this path (see [ADR-0011](0011-observability.md) *Local development*).
- Next.js server logs are structured JSON via **`pino`**, stdout-only, enriched with `trace_id` from the active span. `console.log` is Biome-forbidden.
- Build embeds `SERVICE_VERSION` from the git SHA so traces and errors are version-attributable.

### Performance gates

- `@next/bundle-analyzer` runs in CI; per-route-group budgets in `apps/frontend/perf-budget.json` fail the build on regression.
- **Lighthouse-CI** runs on every PR, with **LCP < 2.5 s**, **INP < 200 ms**, **CLS < 0.1** as merge gates on the mobile profile (the harder bar).
- Images go through `next/image`; fonts through `next/font`. `<img>` and `@font-face` are forbidden.

### i18n: deferred behind a trigger

No i18n library is adopted day one. All user-facing strings live as TS constants in `src/strings/<route-group>.ts` — one file per route group. When the first non-English locale is on the roadmap, an ADR amendment adopts `next-intl` and migrates the strings. The shape (one file per route group) is chosen so the migration is mechanical.

### Feature flags: OpenFeature SDK, noop provider

`@openfeature/web-sdk` is wired with a noop provider day one. Application code calls flags through the OpenFeature API from the start; the concrete backend (GrowthBook, Unleash, Flipt, etc.) is adopted on first gradual-rollout requirement via an ADR amendment. Avoids a rip-and-replace later.

### Build and runtime

- `next build` with `output: "standalone"`. The container runs `bun server.js` (Bun executes the file directly; `bun run` is reserved for package-script names).
- One `apps/frontend/Dockerfile`. Multi-stage: build under `oven/bun:<pinned>`; runtime under the smallest pinned Bun image ([ADR-0001](0001-language-and-runtime.md) — Node.js is not installed).
- Image is `frontend:<git-sha>`, deployed via the shared service chart ([ADR-0004](0004-gitops.md)) with route-group ingress paths declared in `infra/gitops/services/<env>/values/frontend.yaml`.

### Local development

- `mise run -C apps/frontend dev` runs `bun run dev` against `mise run cluster:lite`. SDK requests target services on `localhost` ports established by the cluster:lite port-forwards ([ADR-0003](0003-cluster-topology.md)).
- Work on authenticated surfaces uses the `edge` profile ([ADR-0016](0016-environment-parity.md)): the real Traefik, Kratos, and Oathkeeper with application data served by the API mock ([ADR-0029](0029-api-mocking-and-ui-dev-loop.md)). The app's auth path is identical to production — the frontend carries **no** development-only session, bypass, or `NODE_ENV`-conditional branch in `proxy.ts` or `src/lib/auth/`.
- HMR is left to Next.js defaults; no custom dev server.

## Consequences

### Positive

- Newcomers find the entire frontend story in one ADR plus citations.
- Server-first rendering keeps bundles small without sacrificing the design system.
- A single design-token source (Untitled UI) gives Figma↔code parity for free.
- Biome-only is the smallest possible TS toolchain — install, format, and lint in one binary.
- Form, fetch, and state primitives are repo-wide; route groups do not fork them.
- Browser traces continue the same trace ID as upstream services, closing the loop with [ADR-0011](0011-observability.md).

### Negative / Risks

- **Biome lacks Next-specific lints.** Mitigated by `next build` + Lighthouse-CI + typed `next/image` / `next/font` APIs. Not a behavioural gap, a different enforcement surface.
- **Untitled UI source is vendored, committed.** Upgrading from upstream is a real PR, not a `bun update`. Mitigated by keeping the upstream layout verbatim (clean diffs), `src/components/UPSTREAM.md`, and a yearly bump.
- **OpenTelemetry-JS web SDK is heavier than Faro alone.** Accepted; the trace continuity between browser and services is worth the bytes, re-evaluated under the perf gates.
- **Deferring i18n risks a painful retrofit.** Mitigated by keeping all strings in one file per route group from day one.
- **Server Actions are relatively new.** Mitigated by limiting them to single-service mutations; cross-service flows use the well-trodden REST + workflow-handle path.

### Follow-ups

- `apps/frontend/` scaffold with the four route groups, `proxy.ts`, `loading.tsx` / `error.tsx` baselines.
- `src/components/{base,application,foundations}/` with vendored Untitled UI source, `src/styles/{theme,typography,globals}.css`, and `src/utils/{cx,is-react-component}.ts`.
- `src/lib/server-fetch/` with the server-only fetcher and TanStack Query glue.
- `tools/codegen/zod-gen/` and the `mise run gen:zod` task; inclusion in `mise run gen` and `ci-drift.yml`.
- `biome.jsonc` at repo root with the strict ruleset above.
- `apps/frontend/perf-budget.json` and `apps/frontend/lighthouserc.json`.
- `apps/frontend/Dockerfile` (Bun-only, standalone output).
- `src/lib/observability/{client,server}.ts` wiring OTel-JS, Faro, and `pino`, initialised from `apps/frontend/src/app/observability-init.tsx`.
- `src/proxy.ts` CSP nonce generation and `serverActions.allowedOrigins` in `next.config`.
- `infra/gateway/frontend-observability.yaml` Traefik ingest route for OTel + Faro from the browser.
- `apps/frontend/src/app/api/rum/route.ts` dev-only Faro shim (forwards to local Grafana Alloy via `FARO_COLLECT_URL`, else 204s; 404s in prod where Traefik owns the path) — see [ADR-0011](0011-observability.md) *Local development*.
- `docs/frontend/conventions.md` short pointer file linking back to this ADR.

## Rules

- The frontend is one Next.js App-Router application at `apps/frontend/`. Pages Router is not used.
- Server Components are the default. `"use client"` is added at the smallest interactivity boundary.
- Server Actions are permitted only for mutations against the route group's owning service. Cross-service mutations call the service's REST API and use the workflow-handle pattern from [ADR-0006](0006-temporal.md).
- Every route segment ships `loading.tsx` and `error.tsx`; every route-group root additionally ships `not-found.tsx`.
- First-party frontend code lives in `apps/frontend/src/`; a `libs/ts/*` package is created only for a second consumer or a generated artifact. Generated SDKs under `libs/ts/sdks/` are the only `libs/ts` members.
- Server components fetch via `src/lib/server-fetch/server.ts`. Client components use TanStack Query wrapping the generated SDKs via `src/lib/server-fetch/client.ts`. Direct `fetch` to service URLs is forbidden.
- Hand-written request/response types are forbidden; only types from `libs/ts/sdks/<service>/` are used. Zod schemas for forms are generated from the OpenAPI spec and committed.
- Tailwind v4 is the styling system, wired CSS-first (no `tailwind.config.js`). CSS Modules, CSS-in-JS, and inline `<style>` are forbidden in app code.
- Design tokens come from Untitled UI's `src/styles/theme.css`, imported by `src/styles/globals.css`. There is no JS token mirror; tokens are not redefined per route group.
- Class composition uses `cx`/`sortCx` from `src/utils/cx.ts`. Hand-written `cn()` helpers and `clsx` in app code are not added.
- Primitives are the vendored Untitled UI source under `src/components/{base,application,foundations}/`, built on React Aria Components. Route groups compose them via their explicit `@/components/...` paths; they do not duplicate them.
- A primitive added under `src/components/` is added to `apps/frontend/src/app/(devportal)/devportal/kitchen-sink/page.tsx` in the same PR.
- Icons are `@untitledui/icons`. Other icon sets require an ADR amendment.
- Forms use react-hook-form + zod via the `<Form>` primitive under `src/components/base/`. Hand-rolled form wiring is forbidden.
- URL state uses `nuqs`. Client-only state outside a component tree uses Zustand under `apps/frontend/src/stores/`. Redux and MobX are forbidden.
- The Next.js proxy (`src/proxy.ts`) enforces the Kratos session on `(panel)`, `(devportal)`. The frontend never mints, decodes, or validates JWTs.
- CSP is set in `src/proxy.ts` with a per-request nonce (`script-src 'nonce-<x>' 'strict-dynamic'`); inline scripts are forbidden and `connect-src` allowlists the telemetry ingest origin. Static security headers are duplicated at the Traefik edge ([ADR-0009](0009-api-gateway.md)).
- CSRF rests on `SameSite=Lax` Kratos cookies, Kratos's built-in protection for auth flows, and Next.js Server Actions' `Origin` check (`serverActions.allowedOrigins`). Other cookie-authenticated mutations are Origin-checked at the edge.
- Biome is the only lint+format tool, configured with the strict ruleset in `biome.jsonc`. ESLint is not installed.
- `bun test` covers unit/component tests with `happy-dom` preloaded via `bunfig.toml`; Vitest and Jest are not used. End-to-end and visual-regression tests are owned by [ADR-0018](0018-testing-strategy.md) (Playwright, repo-root `e2e/`); MSW and the development API mock ([ADR-0029](0029-api-mocking-and-ui-dev-loop.md)) are both forbidden there.
- The frontend contains no development-only authentication code. Authenticated local development runs the real Kratos in the `edge` profile ([ADR-0016](0016-environment-parity.md), [ADR-0029](0029-api-mocking-and-ui-dev-loop.md)); a session bypass or fake session object in `proxy.ts` or `src/lib/auth/` is a review-blocker.
- Browser observability is OpenTelemetry-JS + Grafana Faro, exporting through a Traefik-fronted ingest route to the cluster's OTel Collector gateway ([ADR-0011](0011-observability.md)).
- Server-side logs are structured JSON via `pino` to stdout. `console.log` is Biome-forbidden.
- Bundle budgets in `apps/frontend/perf-budget.json` and Lighthouse-CI thresholds (LCP < 2.5 s, INP < 200 ms, CLS < 0.1, mobile profile) are merge gates.
- Images go through `next/image`; fonts through `next/font`. `<img>` and `@font-face` are forbidden.
- No i18n library is adopted; user-facing strings live in `src/strings/<route-group>.ts`. A locale beyond English requires an ADR amendment adopting `next-intl`.
- Feature flags go through `@openfeature/web-sdk` with a noop provider day one. The concrete backend is adopted via an ADR amendment on first gradual-rollout requirement.
- The container runs `bun server.js` from a Next.js standalone build. Node.js is not installed in the image.
