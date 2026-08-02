# Local development loop

Per [ADR-0003](adr/0003-cluster-topology.md), k3d is the only local runtime.
`mise run cluster:lite` creates the cluster and applies the lightweight dev
dependencies (Postgres, Temporal, OpenFGA) from `infra/local/deps.yaml`. The
inner loop is **native execution**: you run the service you are changing directly
on the host against those dependencies — no image build, no in-cluster redeploy,
no file-watch on the hot path.

This file is editor-agnostic. Any IDE that can load a `.env` file and run a Go
`main.go` works the same way.

## One-time setup

```sh
mise run setup                       # lefthook hooks
cp services/<svc>/.env.example services/<svc>/.env   # per service you work on
```

Every service ships a `.env.example` listing exactly the variables it reads, with
values already pointing at the port-forwarded deps. Its `.mise.toml` loads `.env`
(`_.file`), so `mise run server` needs no inline environment. `.env` is gitignored;
`.env.example` is the tracked contract.

## Inner loop (native)

```sh
mise run cluster:lite  # k3d + a CNI + deps (Postgres, Temporal, OpenFGA)
mise run dev:forward   # port-forward the deps to localhost (leave running in its own terminal)
mise run db:migrate    # apply each service's migrations to the local Postgres

cd services/catalog
mise run server        # http server → http://localhost:8080
mise run worker        # temporal worker (orders, payment, orgs)
```

`dev:forward` exposes Postgres (`localhost:5432`), Temporal (`7233` gRPC / `8233`
UI), and OpenFGA (`localhost:18080`) so the host process — and tools like `psql` —
can reach them. OpenFGA is forwarded to `18080`, not its own `8080`, because the
service under test already serves on `8080` (and k3d maps host `8080` to the edge);
`OPENFGA_API_URL` in each service's `.env.example` points at `18080` to match. Re-running the service is just re-running the binary; there is nothing to
rebuild or redeploy. To debug, point your editor's Go run configuration at
`services/<svc>/cmd/server/main.go` and have it load that service's `.env`;
breakpoints and hot-restart work because the service is a plain host process.

Every server hardcodes `:8080`, so only one can run natively at a time. To exercise
a service that calls another (orders → catalog/payment), deploy the callee into the
cluster with `mise run service:deploy -- catalog` and override `CATALOG_URL` /
`PAYMENT_URL` in `.env` — their defaults are in-cluster DNS, which a host process
cannot resolve.

### Putting a service *in* the cluster (edge/auth/e2e)

When you need the service behind the edge (not the native hot path), do a one-shot
build-import-deploy — no watch loop:

```sh
mise run service:deploy -- catalog       # build → k3d image import → helm upgrade
mise run service:undeploy -- catalog     # helm uninstall
```

## Building UI: the `edge` profile

The inner loop runs **one** service natively, and a frontend is nobody's single
client — one panel screen fans out across `/products`, `/orders`, `/orgs`, and
`/charges`. The full platform serves them for about 7 GiB, none of which renders a
table. [ADR-0029](adr/0029-api-mocking-and-ui-dev-loop.md) fills that gap by
inverting the usual split: **the edge and the identity stack stay real, the
application services are replaced by their own OpenAPI contract.**

```sh
mise run cluster:edge   # Traefik + cert-manager + Kratos + Oathkeeper + Postgres + the API mock
cp apps/frontend/.env.example apps/frontend/.env.local
bun run --cwd apps/frontend dev                          # host :3000, reached through the edge
```

Then open <https://dev.localtest.me:8443/> and **log in for real** — the task seeds
the committed test identities from `e2e/fixtures/identities.ts` (the same ones the
e2e suite uses; `mise run auth:seed` re-seeds alone), and a Kratos session lasts 7
days, so this is a weekly event, not a per-run one. What you get is the production
authentication path: real cookie, real CSRF, real expiry, real `proxy.ts` redirect on
a gated route, and every `/api` call decided by the same Oathkeeper access rules
production runs. The frontend carries **no** development-only auth code — no bypass, no
fake session, no `NODE_ENV` branch in the session path — and `mise run
lint:auth-inline` fails the build if one appears.

The mock serves `apps/frontend/public/devportal/openapi/internal.json`, the same
committed projection the developer portal renders, and nothing else: no aggregate,
no fixture files. So refreshing it after a contract change is two commands:

```sh
mise run gen:openapi-public && mise run cluster:edge
```

Response bodies come from the spec's `example`/`examples` first and fall back to
schema generation only where none exists — which is why the fidelity work belongs in
`services/<svc>/openapi.yaml`, where the portal benefits too. `MOCK_DYNAMIC=1`
generates everything instead, for an endpoint whose examples do not exist yet.
`kubectl -n platform logs deploy/api-mock` opens with the routes it registered — the
first thing to read when a path 404s.

For landing pages and other logged-out surfaces, skip the cluster entirely:

```sh
mise run mock:start    # one container on 127.0.0.1:4010
mise run mock:logs     # the routes it registered
mise run mock:stop
```

with `MOCK_API_ORIGIN=http://127.0.0.1:4010` in `.env.local`. There is no login
here, so a gated route redirects to a login page that is not running; that is the
tier, not a bug.

**What this tier cannot tell you.** It is stateless: a create is not reflected by
the next read, a `WorkflowHandle`'s `result_url` polls nothing, and no authorization
decision is real (the mock returns the same rows to everyone — for building a table,
ownership-correct rows teach you nothing). Persistence, Temporal behaviour, and
authorization are asserted against real services on `cluster:full`, which is also
where the e2e suite runs: the mock is forbidden in `mise run test`, `ci:affected`,
and the e2e and visual suites ([ADR-0018](adr/0018-testing-strategy.md)).

## Teardown

```sh
mise run cluster:stop        # stops the cluster, keeps the image cache + volumes
mise run cluster:delete       # deletes the cluster (reclaims disk, forces a clean recreate)
```

## After a reboot

If the whole cluster is stuck (every pod `ContainerCreating`, Cilium down) after
your machine rebooted, it's almost always the node's `host.k3d.internal` alias:
Docker's restart policy replays the node container raw, skipping the k3d start
step that injects it, so image pulls fail and the CNI never comes up. Heal it:

```sh
mise run cluster:heal        # stop + start so k3d re-injects host.k3d.internal
```

This is idempotent; run it whenever the cluster looks wedged after a reboot.

## End-to-end & visual tests

End-to-end and visual-regression tests are owned by [ADR-0018](adr/0018-testing-strategy.md):
**Playwright** drives them from the repo-root `e2e/` workspace against the full platform.

```sh
mise run cluster:full         # the environment e2e runs against (ArgoCD-driven)
mise run e2e:smoke            # product golden path + a key dashboard render
mise run e2e                  # full suite: every journey, every dashboard, all visual baselines
```

The browser test is the acceptance gauge — a rendered, authenticated dashboard (Grafana,
Hubble UI, Temporal) is the proof the whole stack underneath is wired. A Go/shell **preflight
readiness** check runs first so a red e2e reads "infra down" vs "app broken". The suite ships a
committed deterministic test identity (an AAL1 user + an AAL2 operator); there is nothing to seed
by hand. Playwright's runner is Node — one of the three sanctioned Node exceptions
([ADR-0001](adr/0001-language-and-runtime.md)), all of them vendored third-party
tools rather than code we author: this runner (scoped to `e2e/` and CI), the Lowdefy
console image, and the API mock container. Everything we write stays on Bun.

## Load & performance tests

E2e answers *is it correct* at a load of about one user. *What does it cost and where does it
break* is [ADR-0027](adr/0027-load-and-performance-testing.md): **k6** driving the edge from the
repo-root `perf/` workspace, against the same `cluster:full`.

```sh
mise run perf:seed            # bulk catalog rows, so the read path has a realistic table
mise run perf:smoke           # ~30s — are the scenarios still wired to the API?
mise run perf                 # the steady baseline (~7min), nightly + pre-release
mise run perf:stress          # ramp to saturation; thresholds are meant to break here
```

Metrics leave k6 over OTLP into the cluster's collector, so a run shows up in Grafana on the
**`Load test`** dashboard next to the pod CPU/memory it caused — that correlation is the point.
k6 runs its own embedded JS engine, so `perf/` adds **no** Node and no npm; the sanctioned Node
island stays `e2e/` alone. Full guidance, including how to read the shapes, is
[docs/perf/runbook.md](perf/runbook.md).

These suites are not part of `mise run test` or `check`, and never implicitly gate a merge.

## Formatting & linting

`mise run format` / `mise run lint` cover every language, including Markdown.
Generated code is never linted or formatted: Go SDKs (ogen) and sqlc store code
are skipped via `exclusions.generated` in `.golangci.yml` (both `golangci-lint
run` and `golangci-lint fmt`), the TS SDKs and admin `_generated/` via
`biome.jsonc`, and rumdl via `.rumdl.toml`.
Markdown is governed by **rumdl** (`.rumdl.toml`), the single source of truth for
both linting and formatting. `mise run format:md` (`rumdl fmt`) auto-fixes most
rules and runs on staged `.md` files via the lefthook pre-commit hook. For inline
editor warnings that match CI exactly, point your editor at rumdl's LSP
(`rumdl server`) — the repo stays IDE-neutral and ships no editor config.

**Tables** are the one thing `--fix` can't repair. `MD060` enforces *aligned*
tables (whitespace-padded columns) — the exact format the JetBrains
"Incorrect table formatting" inspection wants, so CI and the IDE agree. When a
table is flagged, align it with **Alt+Enter → "Reformat table"** in JetBrains
(note: plain `Ctrl+Alt+L` does *not* align Markdown tables — only that quick-fix
does). Outside JetBrains, align the columns by hand to satisfy CI.

## The full platform: `mise run cluster:full`

The edge (Traefik + Ory Oathkeeper), auth stack (Kratos), and the data tier are
**not** brought up by `cluster:lite` — it only applies the lightweight deps above.
For end-to-end work, the edge, auth, NetworkPolicy, or observability on a laptop,
`mise run cluster:full` (scripts/cluster-full.sh) stands up the **same charts
production runs**, at a single replica ([ADR-0016](adr/0016-environment-parity.md)),
**delivered by ArgoCD** — the same engine staging/prod use: **Cilium** as the CNI
(real NetworkPolicy + Hubble), **CNPG**, the **Temporal** chart, the **OpenFGA**
chart, in-cluster **MinIO**, the **observability** chart, Traefik + Ory (Kratos +
Oathkeeper), and the Lowdefy console.

`cluster:full` creates the cluster, installs the two components ArgoCD cannot
bootstrap (the CNI and ArgoCD itself), plants the SOPS age key, **builds + pushes the
repo images (the 5 services and the Lowdefy console) to a local registry**, then
applies a local root-app (`infra/gitops/local-bootstrap/`) that syncs committed
**`master`** from the remote. Ordering, readiness, and secret materialisation are
ArgoCD's job (sync waves), not a shell script's. Because it syncs committed `master`,
uncommitted infra needs a push — see [cluster/gitops-local.md](cluster/gitops-local.md);
for fast iteration on uncommitted **service** code use `service:deploy`.

**Local image registry (the CI stand-in).** Prod's GitOps works because CI builds
each repo image, pushes it to ghcr, and Argo pulls it. Locally there is no CI, so
`cluster:full` builds and pushes those images to a k3d-managed registry
(`k3d-registry.localhost:5000`) at a stable `:local` tag, and the local overlays point
`image.repository` there — Argo then deploys services and Lowdefy **exactly as prod
does**, the only difference being the registry host (the sanctioned env-divergence
point). The registry is wired at cluster-create via `--registry-use`, so a pre-existing
cluster must be recreated once to gain it. **One-time host setup:** add
`127.0.0.1 k3d-registry.localhost` to `/etc/hosts` so the host `docker push` resolves
the registry to IPv4 (bare `*.localhost` resolves to IPv6 `::1` on some systems, which
the registry does not listen on). This mirrors the proxy: machine setup, never in the
repo. The only components still installed imperatively are the two ArgoCD cannot
bootstrap (Cilium and ArgoCD) — the same pair prod bootstraps before GitOps takes over.

Local diverges from prod **only** through one values overlay,
`infra/gitops/platform/local/values.yaml`, consumed the same way the ArgoCD
ApplicationSet consumes the dev/staging/prod overlays. The only genuine local
substitutions are: in-cluster MinIO instead of the off-cluster bucket (S3 API both
sides), cert-manager with a **self-signed** `*.dev.localtest.me` wildcard issuer
(same mechanism as prod's Let's Encrypt), and a **committed throwaway age key** so
SOPS decrypts locally exactly as it does in prod (the `sops-operator` materialises
every credential from `infra/gitops/platform/local/secrets/platform.enc.yaml` —
only the age key itself is created imperatively). Plan for ~16GB free RAM. Tear
down with `mise run cluster:stop` (keep the cache) or `cluster:delete` (delete).

### Endpoints

Everything is served from one origin, **`https://dev.localtest.me:8443`** (real DNS
→ 127.0.0.1, self-signed wildcard TLS — accept the cert once). The edge (Traefik)
matches longest-prefix, so the specific routes below win over the `/` catch-all.

| URL                                                            | What it gives you                     | Auth           | Defined in                                       |
|----------------------------------------------------------------|---------------------------------------|----------------|--------------------------------------------------|
| `/`                                                            | Landing page (host-run `next dev`)    | public         | `infra/local/edge-auth.yaml`                     |
| `/panel`, `/devportal`                                         | Frontend authenticated areas          | Kratos session | `apps/frontend/src/proxy.ts`                     |
| `/auth/login`, `/auth/registration`, …                         | Kratos UI pages (host-run `next dev`) | public         | `infra/local/edge-auth.yaml`                     |
| `/auth/self-service`, `/auth/.well-known`, `/auth/sessions`    | Kratos public API                     | public         | `infra/local/edge-auth.yaml`                     |
| `/api/products`, `/api/orders`, `/api/orgs`, `/api/charges`    | Service APIs (flat `/api/<resource>`, ADR-0017) | Oathkeeper | `infra/helm/service/templates/ingressroute.yaml` |
| `/api/rum`                                                     | Faro/RUM browser-telemetry ingest     | public         | `infra/gateway/frontend-observability.yaml`      |

The **ops tier** (ADR-0017) is a separate origin per operator dashboard under
`*.ops.<host>` — never a product path. The **coarse gate** is a claim, not a
OpenFGA call: the ops forward-auth requires the `operator` trait **and** an AAL2
session, and makes no `Checker` call, so the debugging surface never shares fate
with the product authz plane ([docs/ops/break-glass.md](ops/break-glass.md)). A
bare login does not grant tool access. Per-tool `dashboard:<tool>#view` grants are
the **optional fine layer** (`OPS_FINE_GRAINED`), off by default.

The local edge is published on the unprivileged port **`:8443`** (see the URLs
below); deployed envs terminate on standard `443` and omit the port.

The **Auth** column shows the always-on coarse gate (`operator` claim + AAL2); the
optional per-tool `dashboard:<tool>#view` fine layer is off by default. Every route
below is defined in `infra/gateway/ingressroutes.yaml` (the opt-in tools' routes
resolve to a backend only once their chart is enabled).

**Which observability panel?** They are a sequence, not a choice ([ADR-0025](adr/0025-service-map-apm-ui.md)):
start at **Grafana** for *"is something wrong, and where?"* (Applications overview → service detail:
SLOs, RED, resources, logs, traces, profiling), then escalate to **Hubble UI** for *"what talks to
what, and is the network denying something right now?"* (live service map, flows, drop verdicts).
Drop *history* and the `PolicyDropsDetected` alert stay in Grafana — the UI keeps no history.

Ops hostnames are named after the tool, always ([ADR-0017](adr/0017-url-and-domain-structure.md)).

| Ops URL                                        | Tool                                                                                   | Auth                                             |
|------------------------------------------------|----------------------------------------------------------------------------------------|--------------------------------------------------|
| `https://grafana.ops.dev.localtest.me:8443/`      | **Grafana** — metrics/logs/traces, RUM, policy drops                                   | operator + AAL2                                  |
| `https://hubble.ops.dev.localtest.me:8443/`       | **Hubble UI** — live service map, network flows, drop verdicts                          | operator + AAL2                                  |
| `https://temporal.ops.dev.localtest.me:8443/` | **Temporal Web UI**                                                                    | operator + AAL2                                  |
| `https://minio.ops.dev.localtest.me:8443/`        | **MinIO console** (non-prod)                                                           | operator + AAL2, then `minio` / `minio-password` |
| `https://lowdefy.ops.dev.localtest.me:8443/`     | **Lowdefy** admin console                                                              | operator + AAL2                                  |
| `https://argocd.ops.dev.localtest.me:8443/`    | **Argo CD**                                                                            | operator + AAL2                                  |
| `https://headlamp.ops.dev.localtest.me:8443/`       | **Headlamp** — k8s debug UI (r/o, [ADR-0024](adr/0024-kubernetes-debug-ui.md))         | operator + AAL2                                  |
| `https://pgweb.ops.dev.localtest.me:8443/`        | **pgweb** — read-only DB inspector ([ADR-0012](adr/0012-internal-admin.md))            | operator + AAL2                                  |

Grafana trusts the Oathkeeper edge and serves anonymously (its login form is
disabled, `auth.anonymous` Admin) — an operator who clears the edge lands straight
on the dashboards, no second login. Without the edge you can still reach it by
port-forward: `kubectl -n platform port-forward svc/grafana 3000:80`, then
<http://localhost:3000/> (anonymous Admin; it serves at root, not a sub-path).

The **MinIO console** is the one dashboard that keeps a second login: unlike
Grafana/Argo CD (which trust the Oathkeeper edge and serve anonymously), MinIO's
console has no proxy-trust/SSO mode, so after the edge gate it prompts for MinIO
credentials — the pre-seeded root user `minio` / `minio-password`.

`cluster:full` brings up the whole platform (edge, services, observability,
console); Argo CD itself is installed imperatively for the local full tier and is
reachable at `argocd.ops.<host>` like the other dashboards. Headlamp (`headlamp.ops`)
and pgweb (`pgweb.ops`) are Core ops tools, on in every environment
([docs/operational-surface.md](operational-surface.md)); a project that does not
want one drops it with `enabled: false` in its env values overlay.

### Login flow

The edge serves `*.dev.localtest.me` on `:8443` (real DNS → 127.0.0.1, no
`/etc/hosts` edits). Auth-gated routes (e.g. the Hubble UI service map at
`https://hubble.ops.dev.localtest.me:8443/`) redirect an unauthenticated browser to
Kratos at `…/auth/login`; register/login there and the redirect returns you to the
gated page. The Kratos session cookie is scoped to `dev.localtest.me` (parent
domain), so one login covers the edge and every `*.dev.localtest.me` subdomain. The landing page and `/auth` UI are
served by a host-run `next dev`
(run `mise run dev:frontend` on the host — the dev server is not in-cluster), wired
through `infra/local/edge-auth.yaml`.

Kratos starts with an empty identity store. Either seed the committed test
identities — `mise run auth:seed`, the same pair the e2e suite and the `edge`
profile use (`e2e/fixtures/identities.ts`) — or register your own at
<https://dev.localtest.me:8443/auth/register> with any email and a password
that clears the policy (≥ 12 chars and not similar to the email, so `password123`
is rejected). Only self-service registration fires the `after` web_hook that creates
a personal org; admin-seeded identities skip it. Email
verification is configured but the local SMTP sink isn't wired up, so verification
mail isn't delivered — login doesn't require it.

Start the host dev server with **`mise run dev:frontend`**, which is `next dev -H
0.0.0.0` plus the two env vars a host process needs to behave like the in-cluster
frontend:

| Env var                            | Why                                                                                                                                                                                                                                                                                                          |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `EDGE_ORIGIN=https://dev.localtest.me:8443` | The environment's edge origin. **Server components** fetch through it (`src/lib/server-fetch/server.ts`) — it is the edge, not a service: the `/api/<resource>` IngressRoutes match on `Host(dev.localtest.me)` and Oathkeeper injects identity there. `next.config.mjs` also derives the **server-action** CSRF allowlist from it. Unset, `/panel/products` throws at the first fetch. |
| `NODE_TLS_REJECT_UNAUTHORIZED=0`   | The local wildcard cert is signed by the SelfSigned `ClusterIssuer` — a self-signed leaf, not a CA — so Node cannot be taught to trust it via `NODE_EXTRA_CA_CERTS`. Local only; deployed envs have Let's Encrypt certs and set neither var.                                                                     |

Starting the dev server another way — an IDE run config, a debugger — needs the
same env: copy `apps/frontend/.env.example` to `.env.local`, which Next loads
before evaluating `next.config.mjs`.

Browser-side calls need no such variable: `client.ts` uses a relative `/api`, which
is the same origin by construction ([ADR-0017](adr/0017-url-and-domain-structure.md)).
A server-side `fetch` has no document to resolve a relative URL against, so the
origin has to be named once — and it must be configuration, not the request's
`Host` header, because that header is client-controlled and this fetcher forwards
the user's session cookie.

```sh
mise run dev:frontend
```

The full Kratos self-service set is served under `/auth/` — `login`, `register`,
`recovery`, and `settings` (these are frontend pages, identical in every env, not
local-only).

> On a restricted network whose registry blocks **digest** pulls (only tags
> resolve), pre-pull the platform images by tag and `k3d image import` them; the
> upstream charts pin images by digest. A normal connection pulls them directly.

## HTTP proxies

Proxy configuration is a property of **your machine**, not of this template — the
repo carries no proxy values or logic, and the scripts never will. On a clean
network, skip this whole section. Behind a proxy, do the three one-time steps
below and the `cluster:*` tasks work unchanged.

The steps assume a **loopback** proxy on your host — e.g. privoxy at
`http://127.0.0.1:8118`. Each step is read from a different place (host, a build
container, the k3d node), so the address you write differs — that's the only
subtlety. If your proxy is instead a **routable** address
(`http://proxy.example.com:8080`), it works from everywhere: use it verbatim in
every step and ignore the per-step address notes.

### Step 1 — Proxy the Docker daemon (image pulls)

Create `/etc/systemd/system/docker.service.d/http-proxy.conf`. The daemon runs on
your host, so a loopback proxy stays `127.0.0.1`:

```ini
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:8118"
Environment="HTTPS_PROXY=http://127.0.0.1:8118"
Environment="NO_PROXY=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.svc.cluster.local,127.0.0.1,localhost,.localtest.me"
```

then `sudo systemctl daemon-reload && sudo systemctl restart docker`.

### Step 2 — Proxy Docker builds (the Lowdefy image's npm fetch)

Docker injects `~/.docker/config.json` → `proxies.default` into `docker build` RUN
steps. There the reader is *inside a container*, where `127.0.0.1` would mean the
container itself — so use the **docker-bridge gateway IP** (find it with
`docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}'`, usually
`172.17.0.1`):

```json
{
  "proxies": {
    "default": {
      "httpProxy": "http://172.17.0.1:8118",
      "httpsProxy": "http://172.17.0.1:8118",
      "noProxy": "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.svc.cluster.local,127.0.0.1,localhost,.localtest.me"
    }
  }
}
```

Keep `registry.npmjs.org`/`docker.io` **out** of `noProxy` so they route through the
proxy. A loopback value here is the classic Lowdefy-build failure: `npm` inside the
build can't see the proxy, goes direct, and the firewall blocks it.

### Step 3 — Export the proxy before bringing up the cluster (the k3d node)

Export it in the shell you run `cluster:full` from; write it as **your host** sees it
(loopback stays `127.0.0.1`). At create time `cluster:ensure` injects it onto the k3d
node, rewriting a loopback proxy to `host.k3d.internal` for you:

```sh
export HTTPS_PROXY=http://127.0.0.1:8118
mise run cluster:full
```

Verify the node got it (a loopback proxy should now read `host.k3d.internal`):

```sh
docker exec k3d-platform-server-0 env | grep -i proxy
```

`cluster:ensure` wires the proxy only at **create** time, so export it **before the
first** bring-up. To rewire an existing cluster, recreate it
(`mise run cluster:delete && mise run cluster:full`). If a node restart drops
`host.k3d.internal`, re-add `<gateway-ip> host.k3d.internal` to the node's
`/etc/hosts`.

> **Stalled image pulls through a proxy.** Even with the node proxied, some egress
> proxies time out or truncate large image layers on containerd's single-stream pull
> (Cilium, ArgoCD, and the OpenFGA seed's `openfga/cli` are the usual victims),
> leaving pods in `ImagePullBackOff`. The opt-in **`mise run cluster:unwedge`**
> ([`scripts/cluster-unwedge-images.sh`](../scripts/cluster-unwedge-images.sh))
> recovers them: it host-pulls whatever is stuck (Docker resumes/retries reliably),
> `k3d image import`s it into the node, and restarts the waiting pods. Re-run it — or
> `watch -n15 mise run cluster:unwedge` — while a fresh `cluster:full` converges.
> Clean networks never need it.
