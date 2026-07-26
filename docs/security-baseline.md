# Security Baseline & Per-Instance Compliance

This is the **generic security baseline** every project built from this template inherits — the
controls every serious project should have, independent of domain. Framework-specific compliance
(PCI-DSS, SOC 2, HIPAA, …) is a documented **per-instance escalation** layered on top (last
section), never baked into the template or its ADRs.

It implements the decisions in [ADR-0009](adr/0009-api-gateway.md),
[ADR-0010](adr/0010-auth.md) and [ADR-0017](adr/0017-url-and-domain-structure.md).

## Trust boundaries

Two tiers behind one Traefik edge, isolated at the browser by **separate origins**
([ADR-0017](adr/0017-url-and-domain-structure.md)):

| Tier        | Origin            | Surfaces                                                                                      |
|-------------|-------------------|-----------------------------------------------------------------------------------------------|
| **Product** | `<host>` (apex)   | Next.js app (`/`, `/auth/*`, `panel`/`devportal`), flat `/api/<resource>/*`, telemetry ingest |
| **Ops**     | `*.ops.<host>`    | one origin per operator dashboard (hubble/grafana/argocd/temporal/lowdefy/minio)                  |

- East-west traffic is default-deny via Cilium NetworkPolicy ([ADR-0003](adr/0003-cluster-topology.md)).
- Every gated route passes `strip-identity-headers` → `oathkeeper-forward-auth` → `security-headers`
  (`infra/gateway/middlewares.yaml`), so a client cannot inject identity and every response carries
  HSTS + CSP.
- One Kratos session cookie scoped to the parent `<host>` is shared across tiers; tier isolation is
  enforced by **per-tool authorization + operator AAL2**, not cookie scope (the accepted model in
  ADR-0017; the OIDC token-isolation upgrade is optional).

## Control → enforcing-artefact matrix

| Control | Enforcing artefact | Verified by |
|---------|--------------------|-------------|
| Single auth-config source (no divergence) | canonical `infra/auth/*`, injected via Helm `-f`/`--set-file` + ArgoCD valueFiles/fileParameters | `scripts/lint-auth-inline.sh` (`mise run lint:auth-inline`) |
| Anti-spoofing (no client identity injection) | `strip-identity-headers` middleware before forwardAuth on every gated route | `scripts/lint-strip-headers.sh` |
| Product/ops origin isolation | `{tool}.ops.<host>` IngressRoutes + 2 wildcard certs (`infra/gateway`, `cert-manager`) | `kubectl kustomize infra/gateway`; browser devtools |
| No surface authorized by session alone | ops: Oathkeeper `remote_json` → `services/authz` (`group:operator` + `dashboard:<tool>#view` + AAL2); product `/admin`: RSC `Checker`/role gate; `/api`: in-service `Checker` | `scripts/lint-authorizer.sh`; `services/authz` tests; `fga model test` |
| Least privilege (per-tool grants) | OpenFGA `group`/`dashboard` schema + relations | `scripts/validate-openfga.sh` (13 assertions) |
| Operator MFA / AAL2 | Kratos TOTP + WebAuthn enabled; AAL2 required at the ops edge (`services/authz`); enrolment UI via `KratosFlow` | authz unit tests (aal2 deny); manual enrolment |
| Strong passwords | Kratos `password` method: `min_password_length: 12` + identifier-similarity check (`infra/auth/kratos/values.yaml`). HIBP breach check is off by default and enabled per env ([ADR-0010](adr/0010-auth.md)) | rendered Kratos config |
| Session lifetime + step-up | `session.lifespan: 168h`; `privileged_session_max_age: 15m` on settings/MFA changes | rendered Kratos config |
| Account recovery (enumeration-resistant) | Kratos recovery/verification `use: code` | rendered Kratos config |
| Managed secrets (no plaintext) | SOPS-managed `kratos-secrets` (cookie/cipher/system/dsn) via `secret.enabled:false` + existingSecret; same mechanism for every credential ([ADR-0005](adr/0005-secrets.md)) | rendered deployment secretKeyRefs; `grep` for plaintext |
| Encryption in transit | TLS at the edge (cert-manager wildcard certs); HSTS `max-age=63072000; includeSubdomains; preload` | `security-headers` middleware |
| Browser hardening | strict per-request nonce CSP (`apps/frontend/src/proxy.ts`); `frame-ancestors 'none'`, `object-src 'none'` per origin | `proxy.ts`; `security-headers` |
| Abuse / brute-force | `auth-ratelimit` (10/min/IP, burst 20) on `/auth/self-service/*` (login/registration/recovery/MFA) | `infra/local/edge-auth.yaml` |
| Auth audit trail | structured per-decision events from `services/authz` (actor, tool, outcome) + Kratos/Oathkeeper logs → Loki ([ADR-0011](adr/0011-observability.md)) | `services/authz` logs |
| CI enforcement | `mise run lint` runs `lint:auth-inline` + `lint:authz` (fga model test + authorizer-ban + anti-spoof) | `.github/workflows/lint.yml` |

### Cookie prefixes

The session cookie is `Secure` + `HttpOnly` + `SameSite=Lax`. The `__Host-` prefix is **not**
applicable: it forbids a `Domain` attribute, but the cookie is deliberately `Domain=<host>`-scoped to
be shared across the product apex and `*.ops.<host>` (ADR-0017). The `__Secure-` prefix is compatible;
adopting it means renaming `ory_kratos_session` in Kratos, Oathkeeper (`only:`) and `proxy.ts` together
— tracked as a per-instance hardening, not a baseline default.

## Deliberately deferred (enable per-instance when the need arises)

These are conscious omissions from the baseline, not unfinished work — each is a values/policy flip a
specific project turns on when it needs it:

- **Per-account lockout / CAPTCHA**: Kratos OSS relies on the edge IP rate-limit; per-account backoff
  and a CAPTCHA hook on registration/recovery are per-instance add-ons where the product needs them.
- **Ops-tier OIDC (Hydra)**: optional token-isolation upgrade (ADR-0017); mandatory only if a
  non-first-party origin is ever hosted under `<host>`.
- **B2C MFA, social/SSO, SCIM**: deferred/optional per ADR-0010.

## Per-instance compliance escalation

A project reaches a named framework by **layering on top of this baseline, without forking the
template**:

- **Audit retention**: extend the Loki retention for the auth audit stream to the framework's window
  (e.g. SOC 2 ≥ 1 year) via the per-env observability values — the events already flow.
- **Network segmentation**: tighten the default-deny NetworkPolicies and add per-namespace isolation
  for regulated data paths.
- **Encryption at rest**: enable storage-class / database encryption in the per-env infra
  (Terraform/CNPG values); the template is cloud-agnostic.
- **Stronger authN**: flip B2C MFA to required, add the OIDC token-isolation upgrade, shorten session
  lifetimes, enable `__Secure-` cookie prefixes.
- **Access reviews**: schedule periodic review of `group:operator` and `dashboard:*#viewer` grants
  (OpenFGA relations are the source of truth).
- **Scans / attestations**: add image scanning, SBOM, and pen-test attestations in CI — none require
  template changes.

Each escalation is a values/policy overlay or a CI addition; the baseline controls above remain the
floor every instance starts from.
