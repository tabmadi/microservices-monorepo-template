// Server-only fetcher (ADR-0014). Wraps openapi-fetch so server components
// call services with the Kratos session cookie and W3C trace context attached.
// Client components must use ./client.ts.
import "server-only";

import { headers } from "next/headers";
import createClient, { type Client } from "openapi-fetch";

const API_BASE_URL =
  process.env.API_BASE_URL ??
  `${process.env.INTERNAL_API_BASE ?? "http://gateway.platform.svc.cluster.local"}/api`;

// Flat API (ADR-0017): server components call the in-cluster edge under the shared
// /api prefix; the typed resource path selects the endpoint, service topology hidden.
export async function createServerClient<Paths extends object>(): Promise<Client<Paths>> {
  const h = await headers();
  const cookie = h.get("cookie") ?? "";
  const traceparent = h.get("traceparent") ?? "";

  return createClient<Paths>({
    baseUrl: API_BASE_URL,
    headers: {
      ...(cookie && { cookie }),
      ...(traceparent && { traceparent }),
    },
  });
}
