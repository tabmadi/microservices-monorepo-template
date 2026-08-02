# ADR-0002: Monorepo Structure & Build

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Platform team
- **Related:** [ADR-0000](0000-platform-foundations.md), [ADR-0001](0001-language-and-runtime.md)

## Context

At the target scale ([ADR-0000](0000-platform-foundations.md)), the monorepo hosts the full fleet of backend services, one frontend application,
shared Go/TS libraries, generated API clients, infrastructure-as-code, and tooling. Every engineer on the team touches
it. The naive "every PR runs every test in every package" approach does not survive past ~20 services.

We need a single answer to:

- **Repository layout** — where code lives.
- **Task invocation** — how `build`, `test`, `lint`, `generate`, `migrate` are run consistently across languages and
  services.
- **Workspace tooling** — how Go and TypeScript packages reference each other locally without `replace` directives,
  `go.work` overlays, or `npm link` ceremony.
- **CI** — which provider, how it knows what changed, how it caches.
- **Codegen** — committed or rebuilt; how drift is caught.
- **Frontend topology** — one app or many.

## Decision drivers

1. **One task entry point per concern.** `mise run test` does the right thing in any directory.
2. **Native caches first.** Go's build/test cache, Docker BuildKit, Bun's install cache. Higher-level orchestration is
   added only when these are insufficient.
3. **Affected detection is mandatory.** Running every test on every PR is acceptable only up to ~10 services.
4. **Local and CI run the same commands.** No CI-only shell scripts.
5. **Build-graph tools (Bazel, Nx) are an upgrade path, not a starting point.** Their value is dominated by team size,
   which is our bottleneck.

## Repository layout

```text
go.mod                        # single Go module for the entire repo
go.sum

services/<name>/              # one backend service (package, not a module)
├── openapi.yaml
├── cmd/{server,worker}/
├── internal/{handlers,workflows,activities,domain,store}/
├── migrations/
├── Dockerfile
└── .mise.toml

apps/
├── frontend/                 # one Next.js app, route groups inside
│   └── src/app/(landing|panel|devportal)/
└── admin/                    # Lowdefy YAML config for internal admin (ADR-0012)
    ├── lowdefy.yaml
    ├── _generated/<service>/ # codegen from OpenAPI, drift-checked
    └── custom/<service>/     # hand/LLM-written pages

libs/
├── go/                       # all shared Go (single go.mod, no per-library module)
│   ├── <name>/               # shared Go packages
│   └── sdks/<service>/       # generated Go server + client
└── ts/                       # all shared TS (workspace / path-alias root)
    ├── <name>/               # shared TS libraries
    └── sdks/<service>/       # generated TS client

infra/
├── terraform/                # cluster + DNS + LB provisioning
├── helm/                     # Helm charts (ours + values for upstream)
├── gitops/                   # ArgoCD ApplicationSets + per-env values
├── ansible/                  # host configuration
├── auth/                     # Kratos, Hydra, OpenFGA config
├── gateway/                  # Traefik routing + rate-limit config (Oathkeeper rules live in infra/auth/)
└── observability/            # dashboards and alerts as code

tools/                        # repo-local Go programs (codegen helpers, affected, lint plugins)
docs/                         # ADRs, runbooks, conventions
.github/workflows/            # CI definitions
```

`services/` and `apps/` are siblings on purpose: services are headless, horizontally-scaled, internally-addressed
backends; `apps/` holds first-party deployable applications (`frontend/` and `admin/` today; the slot remains
open for future partner portals, CLIs, or mobile apps without requiring a layout migration).
Adding a new application under `apps/` requires its own ADR — `apps/admin/` is the subject of
[ADR-0012](0012-internal-admin.md).

`services/` stays spelled out (unlike `apps/`, `libs/`, `infra/`): the short forms `svc`/`svc/` already mean
a Kubernetes Service here (`kubectl … svc/grafana`) and the per-service metavariable in docs (`services/<svc>`),
so abbreviating the directory would overload the token. Directory names abbreviate only when unambiguous.

`infra/` is a single home for everything not-an-application: infrastructure-as-code (Terraform, Helm, GitOps, Ansible)
*and* the configuration of the platform services those tools deploy (auth, gateway, observability). One top-level
directory avoids the recurring "does this belong in infra or ops?" bikeshed.

`tools/` is for repo-local Go programs and lint plugins (e.g., `tools/affected/`). It is not a shell-script junk drawer.
External tools (Go, sqlc, dbmate, helm, kubectl, etc.) are installed via `mise` and never live here.

## Decisions

### Task runner: mise

`mise` is the single entry point for tasks and tool versions.

- Tasks are defined in `.mise.toml` files: a root file declares repo-wide tasks; each service has its own with
  service-local tasks.
- **Standard task names** at every service: `build`, `test`, `lint`, `generate`, `migrate`, `server`, `worker`.
  The two long-running tasks are named for the process type they start, matching `cmd/{server,worker}/`, the
  `<service>-{server,worker}` images, and the in-cluster DNS names — one vocabulary end to end. (Frontends are not
  services and keep `run`: they have no worker to be symmetric with, and the task starts a dev server, not a
  production binary.)
- **Standard task names** at repo root: `cluster:lite`, `cluster:stop`, `ci:lint`, `ci:test`, `ci:build`, `ci:affected`,
  `e2e`, `e2e:smoke`, `gen`, `db:migrate`. The `e2e` tasks ([ADR-0018](0018-testing-strategy.md)) run against `cluster:full`
  and are deliberately outside `ci:affected` — every e2e crosses service boundaries.
- **Task naming convention.** A task name is `group:member`, where the **group is the axis you want to list and
  run together** — pick it by asking "what would I browse or aggregate by?" Two shapes fall out, and both are correct:
  - **`activity:target`** when one activity fans out across many targets, with an umbrella task that runs them all:
    `lint:go`/`lint:ts`/`lint:md` (umbrella `lint`), `format:*`, `gen:openapi`/`gen:sqlc` (umbrella `gen`), `upgrade:*`.
  - **`resource:operation`** when a stateful thing has a lifecycle you want grouped: `cluster:ensure`/`stop`/`delete`,
    `service:deploy`/`undeploy`, `db:migrate`, `ops:grant`.

  Don't force one literal shape on both — homogenizing would scatter a family (e.g. `stop:cluster`/`delete:cluster`
  splits the cluster lifecycle; `ts:format`/`md:format` breaks the `format` umbrella). Use `activity:` only when a
  real fan-out/umbrella exists; otherwise group by the resource. Graph-only plumbing (a task that exists solely as a
  `depends` node, e.g. `cluster:cilium`) is marked `hide = true`.
- `mise tasks --list` is the discoverable interface.

### Tool versioning: pinned in mise or in a container tag

Every executable the repo depends on is pinned to a specific version in one of exactly two places:

- **Developer / CI tools** (Go, Bun, `dbmate`, `sqlc`, `sqruff`, `ogen`, `vacuum`, `helm`, `kubectl`,
  `terraform`, `ansible`, `fga`, `age`, `sops`, `mise` itself, etc.) live in the root `.mise.toml` (and
  service-local `.mise.toml` files when a service genuinely needs a different version).
- **Runtime services** (Postgres, Temporal, Kratos, Oathkeeper, Hydra, OpenFGA, MinIO, Loki, Prometheus, Tempo,
  Grafana, OTel Collector, ArgoCD, CNPG operator, etc.) live as Helm chart `appVersion` plus an explicit `image.tag` in
  `infra/helm/.../values.yaml`. Local development uses the same Helm values via k3d (
  see [ADR-0003](0003-cluster-topology.md));
  there is no separate compose-based path.

Floating tags (`latest`, `stable`, `main`, an unpinned major) are forbidden everywhere — `.mise.toml`, Dockerfiles, Helm
values, GitHub Actions. CI greps for these patterns and fails the build.

A change of tool version is a normal PR. Anyone cloning the repo at any SHA can reproduce the exact toolchain that built
it.

### Go modules: single repo-wide `go.mod`

- One `go.mod` at the repo root covers every service, library, generated client, and `tools/` program.
- No `go.work`. No per-service or per-library `go.mod`. No `replace` directives.
- Services and libraries are plain Go packages under their respective directories; imports use the repo's module
  path (e.g., `github.com/<org>/<repo>/services/gateway/internal/handlers`).

Rationale. With a small team and a small codebase, dependency *consistency* is more valuable than dependency
*isolation*. A single module means:

- One `go get -u` upgrades the whole repo. Renovate opens one PR per dependency, not N.
- One `govulncheck` / `go mod tidy` / `go.sum` to reason about.
- Cross-cutting refactors (renaming a library function, changing a shared interface) land in one PR with no
  workspace-mode ceremony or staggered module bumps.
- Every service is forced onto the same version of every dependency — drift is structurally impossible.

Accepted trade-offs:

- A service cannot pin an older or newer version of a shared dependency for itself. This is the consistency we are
  buying.
- Extracting a service or library to its own repository becomes a real migration (re-introduce a `go.mod`, rewrite
  import paths, set up a tag scheme). Acceptable: the template targets an internal product, not a library
  ecosystem. When/if that changes, it gets its own ADR.
- A single `go build ./...` compiles more than a single service strictly needs. The native Go build cache absorbs
  this; affected detection (below) keeps CI proportional to PR size.

### TypeScript workspaces: Bun, one Next.js app

The frontend is **one Next.js application** with route groups for `(landing)`, `(panel)`, `(devportal)`.
Reasons:

- Cross-subdomain auth is hostile in modern browsers (Safari ITP especially). Sharing cookies/session across subdomains
  is a recurring source of subtle production bugs.
- Next.js route-level code splitting makes the bundle-size argument for separate apps weak.
- One deploy unit, one Traefik routing surface (`/panel/*` as a path, not a hostname).

A genuinely independent frontend (partner-branded experience, embedded SDK) earns its own ADR — not a reason to fragment
the primary app pre-emptively.

Bun workspaces unify the app and TS libraries:

```jsonc
// package.json (root)
{ "workspaces": ["apps/frontend", "libs/ts/*", "libs/ts/sdks/*"] }
```

**Bun, not pnpm or npm.** Faster install, fewer flags. Lockfile is `bun.lockb`, committed.

**No Turborepo.** With one frontend app, its value does not apply. Re-evaluated only if the frontend grows to multiple
apps (which itself requires a new ADR).

### CI: GitHub Actions

GitHub Actions is the CI provider. Workflows live in `.github/workflows/`:

- `lint.yml`, `test.yml`, `build.yml` route through `mise run ci:lint` / `ci:test` / `ci:build`. These are whole-repo
  over the single Go module, not affected-scoped: the linters have no per-service subset to take, and Go's build cache
  already makes the repeat cost small. `ci:affected` scopes what gets built and promoted, not what gets analysed.
- `ci-drift.yml` runs `mise run ci:gen` (regenerate + reformat) and fails on `git diff --exit-code`.
- Every workflow gets its toolchain from the `./.github/actions/setup` composite action, so mise setup and the Go cache
  key are defined exactly once.
- `publish.yml` builds and pushes container images on merges to `master` (the "release" workflow name is reserved for
  tag-driven prod promotion — see [ADR-0013](0013-release-and-versioning.md)).

Self-hosted runners are not used on day one; GitHub-hosted runners with cache actions are sufficient. Re-evaluated when
CI minutes become a budget item.

### Codegen: committed, drift-checked

All generated code is **committed** to the repo:

- `libs/{go,ts}/sdks/<service>/` — OpenAPI clients.
- `services/<service>/internal/store/` — sqlc output.

Reasons: PR diffs include the generated changes; `go build` works without a codegen step; CI is simpler.

**Drift check:** `mise run ci:gen` regenerates everything and CI fails on `git diff --exit-code`. A lefthook pre-commit
hook runs the relevant slice when source files change.

### Affected detection

A small Go program at `tools/affected/` reads `git diff --name-only origin/master...HEAD` and maps changes to scopes:

| Change under                                           | Affects                                          |
|--------------------------------------------------------|--------------------------------------------------|
| `services/<X>/`                                        | service `<X>`                                    |
| `libs/go/<L>/`                                         | every Go consumer of `<L>` (via `go list -deps`) |
| `libs/go/sdks/<S>/`                                    | every Go consumer of service `<S>`'s client      |
| `apps/frontend/`                                       | the frontend                                     |
| `infra/`, `tools/`, `go.mod`, `go.sum`, `package.json` | **global** — everything runs                     |

`mise run ci:affected` is the entry point; it produces a JSON manifest consumed by the CI workflows.

This program is the most load-bearing piece of repo tooling at scale; it has unit tests.

### Caching

Day one:

- Go build/test cache via `actions/cache`, keyed on the root `go.sum`.
- Docker BuildKit layer cache to GHCR.
- Bun install cache via `actions/cache` on `bun.lockb`.

Remote Go build cache (`GOCACHEPROG` / `sccache`) is the first upgrade lever, adopted when CI time consistently exceeds
15 minutes on the median affected PR.

### Container images

- One multi-stage `Dockerfile` per service under `services/<service>/Dockerfile`.
- Stage 1: build using the workspace `go build`. Stage 2: `gcr.io/distroless/static-debian12`.
- One `Dockerfile` for the frontend (Next.js standalone output).
- Image tag is `<service>:<git-sha>`. The same SHA flows through dev, staging, and prod per [ADR-0004](0004-gitops.md).

**Server and worker are separate images, built from the same Dockerfile.** A `CMD` build arg selects which
`cmd/{server,worker}` binary the build stage compiles, producing `<service>-server:<sha>` and `<service>-worker:<sha>`.
Rationale: server and worker scale independently, have different resource profiles, and should not carry each other's
code surface. A single Dockerfile keeps the build stage and base layers shared and cache-friendly.

No shared base image. Distroless static is sufficient.

### Upgrade path

The day-one stack is `mise + single go.mod + bun + git-diff affected + native caches + GitHub Actions`. It is sized
for ~30–50 services with disciplined dependencies. Beyond that, the documented next steps are:

- **Split the Go module** if a service or library genuinely needs its own dependency line (external publication,
  divergent upgrade cadence, isolated security review). This is a deliberate exit from the single-module model and
  requires its own ADR.
- **Nx** as a multi-language task orchestrator with caching (`mise` keeps managing tool versions). Bazel is
  reserved for the case where hermetic, reproducible builds become a compliance requirement.

Each upgrade is its own ADR when triggered.

## Consequences

### Positive

- `mise run <task>` is the universal interface across languages and services.
- Cross-package Go changes (`libs/` + `services/`) work in one PR with no `replace` directive or `go.work` ceremony.
- Every service is structurally forced onto the same version of every Go dependency — no drift, no per-service
  upgrade backlog.
- One Renovate PR per Go dependency, not N.
- One frontend app removes the entire class of cross-subdomain auth bugs.
- Committed codegen keeps PR review honest and CI simple.
- Affected detection keeps CI runtime tied to PR size, not repo size.
- GitHub Actions piggy-backs on the same SCM; no separate CI control plane.

### Negative / Risks

- Affected detection is custom code; bugs cause "tests passed but the affected service was broken" incidents. Mitigated
  by unit tests on `tools/affected/`, an explicit `--all` fallback flag, and the global-trigger paths that promote any
  shared-infrastructure change to a full-repo run.
- A single `go.mod` means a service cannot pin its own version of a shared dependency. A risky upgrade (e.g., a new
  major version of a database driver) lands repo-wide or not at all. Mitigated by `depguard` rules on sensitive
  packages, and by the explicit "split the module" upgrade path when a service genuinely needs isolation.
- A single `go.mod` couples vulnerability blast radius: a CVE in any transitive dependency flags the whole repo,
  not one service. Mitigated by treating Go upgrades as routine repo-wide work (Renovate, weekly merge).
- Extracting a service or library to its own repo later is a real migration, not a directory move. Accepted —
  the template targets an internal product.
- One frontend app risks becoming a god-app. Mitigated by route-group boundaries enforced by lint and the explicit
  ADR-required path for genuinely independent frontends.
- Committed generated code inflates repo size over time. Mitigated by routine `git gc`/`git repack`.

### Follow-ups

- `tools/affected/` with unit tests.
- Root `.mise.toml`, root `package.json`, root `go.mod`.
- `services/_template/` service skeleton (referenced from later ADRs).
- `.github/workflows/{lint,test,build,ci-drift,publish,promote-on-merge,promote-on-release,e2e}.yml` (`e2e.yml`: nightly + pre-release full suite, plus a label-gated smoke job — [ADR-0018](0018-testing-strategy.md)).
- `depguard` lint rule preventing `services/<X>/` from importing `services/<Y>/`.
- Lint rule preventing cross-route-group imports in `apps/frontend/`.
- Renovate config for the single Go module (one PR per dependency, repo-wide).

## Rules

- The repo is a single Go module rooted at `go.mod`. There are no per-service or per-library `go.mod` files and no
  `go.work`.
- Every backend service lives at `services/<name>/`.
- Every shared Go package lives under `libs/go/<name>/`; every shared TS library lives under `libs/ts/<name>/` (its
  own npm workspace).
- Generated API clients live at `libs/{go,ts}/sdks/<service>/` and are committed.
- The frontend is one Next.js app at `apps/frontend/`. New frontends require an ADR.
- Tasks are invoked via `mise run <task>`. The set of task names at each service is
  `build, test, lint, generate, migrate, server, worker`.
- Every external tool the repo depends on is pinned to a specific version: developer/CI tools in `.mise.toml`, runtime
  services as explicit `image.tag` in Helm values. Floating tags (`latest`, `stable`, `main`, unpinned majors) are
  forbidden and CI fails on them.
- CI runs on GitHub Actions, entered via `mise run ci:affected`.
- A PR that changes a spec, SQL query, or any codegen input must include the regenerated artifacts. CI fails otherwise.
- A change to `go.mod`, `go.sum`, root `package.json`, or anything under `infra/` or `tools/` triggers a full-repo
  CI run.
- Container images are tagged `<service>:<git-sha>`. The same SHA flows through every environment.
- `services/<X>/` does not import `services/<Y>/`. Sharing happens through `libs/` or generated clients.
- Route groups inside `apps/frontend/` do not import from each other.
- Build-graph tools (Nx, Bazel) are not used on day one. Their adoption requires its own ADR.
