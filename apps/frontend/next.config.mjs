// Next.js config (ADR-0014). Standalone output is required for the Bun-only
// Dockerfile. All first-party code lives inside the app, so no transpilePackages.

// Server Actions CSRF allowlist (ADR-0009, ADR-0014), derived from the one edge
// origin this app knows (EDGE_ORIGIN, see src/lib/server-fetch/server.ts) so the
// two never drift. Next compares the list against `new URL(origin).host`, which
// INCLUDES the port — hence `.host`, not the bare hostname: a `dev.localtest.me`
// entry can never match an `https://dev.localtest.me:8443` origin.
//
// This list is only consulted when Origin ≠ (X-Forwarded-)Host. ADR-0017 puts `/`
// and `/api` on the same origin, so that is already the common case and this is
// defence in depth. Note it is BUILD-time: `output: "standalone"` freezes this
// config into server.js, so a deployed image only carries an entry if the build
// passed EDGE_ORIGIN — which pins that image to one env host and breaks the
// build-once/promote-by-digest flow in ADR-0013. Leave it unset in CI builds.
const edgeOrigin = process.env.EDGE_ORIGIN;
const allowedOrigins = edgeOrigin ? [new URL(edgeOrigin).host] : [];

// Standalone-mock mode (ADR-0029): with no cluster there is no edge to serve /api,
// so the dev server proxies it to the mock and the browser keeps the same-origin
// contract ADR-0017 gives it (src/lib/server-fetch/client.ts calls a relative
// /api). The mock serves the spec's paths at root — the same shape the edge's /api
// stripPrefix produces — hence the prefix is dropped on the way through.
//
// Local-only: unset in every deployed environment, and it carries no auth meaning.
const mockApiOrigin = process.env.MOCK_API_ORIGIN;

/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "standalone",
  reactStrictMode: true,
  typedRoutes: true,
  // `cluster:full` serves the host-run `next dev` through the edge at
  // dev.localtest.me:8443 — a different origin than localhost — so allow it,
  // otherwise Next blocks the cross-origin dev/HMR requests. Dev-server-only;
  // the prod build ignores it.
  allowedDevOrigins: ["dev.localtest.me"],
  experimental: {
    serverActions: {
      allowedOrigins,
    },
  },
  env: {
    NEXT_PUBLIC_SERVICE_VERSION: process.env.SERVICE_VERSION ?? "dev",
    NEXT_PUBLIC_DEPLOY_ENV: process.env.DEPLOY_ENV ?? "dev",
  },
  // Stamp the shipped build's identity on every response (ADR-0013), so "did prod
  // actually update?" is answerable from response headers / devtools, and a stale
  // browser bundle is caught by comparing this against the backend's X-App-Version.
  rewrites() {
    return Promise.resolve(
      mockApiOrigin ? [{ source: "/api/:path*", destination: `${mockApiOrigin}/:path*` }] : [],
    );
  },
  headers() {
    return Promise.resolve([
      {
        source: "/:path*",
        headers: [{ key: "X-App-Version", value: process.env.SERVICE_VERSION ?? "dev" }],
      },
    ]);
  },
};

export default nextConfig;
