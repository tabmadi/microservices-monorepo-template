// Server-only fetcher (ADR-0014). Wraps openapi-fetch so server components
// call services with the Kratos session cookie and W3C trace context attached.
// Client components must use ./client.ts.
import "server-only";

import { headers } from "next/headers";
import createClient, { type Client } from "openapi-fetch";

// The environment's edge origin — its PUBLIC origin, not a cluster-internal name:
// the /api IngressRoutes match on Host(<env host>) and Oathkeeper injects identity
// there (ADR-0009/0010), so a call that skips the edge is both unrouted and
// unauthenticated. Deployed envs set it in
// infra/gitops/services/<env>/values/frontend.yaml; local `next dev` gets it from
// the dev:frontend mise task. It is also what next.config.mjs derives the
// server-action CSRF allowlist from.
//
// No default: every candidate is a wrong guess (a cluster DNS name resolves
// nowhere and would 404 on the Host match; localhost is a different app). A
// misconfigured environment should say so, not fail as a DNS error at the first
// server component. It cannot come from the request's Host header either — that is
// client-controlled, and this fetcher forwards the user's session cookie.
const API_BASE = process.env.EDGE_ORIGIN;

// Flat API (ADR-0017): server components call the edge under the shared /api
// prefix; the typed resource path selects the endpoint, service topology hidden.
// The prefix cannot be relative — a server-side fetch has no document to resolve
// against, so the origin is required even though the browser calls the same paths
// same-origin (see ./client.ts).
export async function createServerClient<Paths extends object>(): Promise<Client<Paths>> {
  if (!API_BASE) {
    throw new Error(
      "EDGE_ORIGIN is unset: server components fetch through the edge and need its origin " +
        "(e.g. https://dev.localtest.me:8443). Locally, start the dev server with " +
        "`mise run dev:frontend`; in a deployed env set it in " +
        "infra/gitops/services/<env>/values/frontend.yaml.",
    );
  }

  const h = await headers();
  const cookie = h.get("cookie") ?? "";
  const traceparent = h.get("traceparent") ?? "";

  return createClient<Paths>({
    baseUrl: `${API_BASE}/api`,
    headers: {
      ...(cookie && { cookie }),
      ...(traceparent && { traceparent }),
    },
  });
}
