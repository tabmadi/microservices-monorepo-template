// Shared configuration for every k6 scenario (ADR-0027).
//
// Three things live here so a scenario file contains only its request logic:
//   1. TARGET  — which edge to hit, defaulting to the local one and nothing else.
//   2. PROFILE — the load shape (smoke/load/stress/soak) as data, so one scenario
//      file serves all four instead of being copy-pasted per shape.
//   3. options() — assembles k6's `options` export from a profile + thresholds.
//
// This runs on k6's embedded JS engine (Sobek), NOT Node: there is no npm, no
// package.json and no node_modules in perf/, and there must never be one — that
// boundary is what keeps ADR-0018's Node escape hatch scoped to e2e/.

// ── Target ───────────────────────────────────────────────────────────────────
// Host-agnostic like the e2e suite (e2e/fixtures/env.ts): override PERF_HOST to
// point at a deployed environment. The default is the local edge and only the
// local edge — a load run must never drift onto a shared environment because
// someone forgot a flag (ADR-0027).
export const HOST = __ENV.PERF_HOST || "dev.localtest.me:8443";
export const BASE_URL = `https://${HOST}`;
// Flat resource namespace behind the gateway (ADR-0017). Scenarios drive this,
// not a port-forwarded pod, so Traefik and the Oathkeeper forward-auth hop are
// inside the measurement (ADR-0009, ADR-0027).
export const API = `${BASE_URL}/api`;

// Everything this suite writes carries this prefix, so seeded and load-generated
// rows are identifiable and removable afterwards.
export const PERF_PREFIX = "perf-";

// ── Load profiles ────────────────────────────────────────────────────────────
// `vus` is the profile's headline concurrency; a scenario scales it by its own
// weight (a checkout is far heavier than a product list, so the same profile
// name means fewer VUs there). Override any profile's peak with PERF_VUS.
//
// stages are k6 ramping-vus stages: [{ duration, target }, ...].
const PROFILES = {
  // Proves the script and the target are wired. Cheap enough for a per-PR lane.
  smoke: { vus: 1, stages: (v) => [{ duration: "10s", target: v }] },

  // The steady baseline. This is the number nightly runs track over time, so its
  // shape must stay stable — changing it invalidates the history.
  load: {
    vus: 20,
    stages: (v) => [
      { duration: "30s", target: v },
      { duration: "2m", target: v },
      { duration: "30s", target: 0 },
    ],
  },

  // Ramp past the knee. Thresholds are EXPECTED to break here; the output of a
  // stress run is the step at which they broke, not a pass/fail.
  stress: {
    vus: 20,
    stages: (v) => [
      { duration: "30s", target: v },
      { duration: "1m", target: v * 2 },
      { duration: "1m", target: v * 4 },
      { duration: "1m", target: v * 8 },
      { duration: "30s", target: 0 },
    ],
  },

  // Sustained, for leak detection: memory that climbs while throughput is flat.
  soak: {
    vus: 10,
    stages: (v) => [
      { duration: "1m", target: v },
      { duration: "30m", target: v },
      { duration: "1m", target: 0 },
    ],
  },
};

export const PROFILE = __ENV.PERF_PROFILE || "smoke";

// ── Cardinality control ──────────────────────────────────────────────────────
// ADR-0011 forbids high-cardinality metric labels, and k6's default system tags
// violate that badly against a Prometheus every service shares. This is an
// ALLOW-LIST: any system tag not named here is not emitted. What is deliberately
// missing, and why:
//
//   url, name  the FULL request URL. `GET /products/{id}` against a seeded
//              catalog mints one series per product id — thousands from a single
//              stress run, resident in the TSDB until retention expires them.
//              The hand-written `endpoint` tag on each request carries the route
//              template instead, which is what a dashboard actually groups by.
//   error      the free-text Go error string ("EOF", "connection reset by peer
//              …"). Unbounded by construction. `error_code` below is the
//              enumerated k6 equivalent and is kept.
//   scenario   k6's own value here is the EXECUTOR name ("default"), not the
//              scenario file — useless, and it would collide with the run-level
//              `scenario` tag set in options() below. Dropped so ours wins.
const SYSTEM_TAGS = [
  "proto",
  "status",
  "method",
  "group",
  "check",
  "error_code",
  "expected_response",
];

// options builds the k6 `options` export.
//
//   scenario   this file's name ("browse"/"checkout"), tagged onto every metric
//              so the two runs stay distinguishable in Prometheus.
//   weight     scenario-specific multiplier on the profile's VU count (1 = the
//              profile's headline number; 0.25 = a quarter of it, for heavy paths).
//   thresholds the scenario's budgets. Budgets, not SLOs (ADR-0027) — a load run
//              deliberately pushes past the SLO, so reusing the SLO here would
//              make every run red and teach everyone to ignore it.
export function options(scenario, weight, thresholds) {
  const profile = PROFILES[PROFILE];
  if (!profile) {
    throw new Error(
      `unknown PERF_PROFILE "${PROFILE}" — expected one of: ${Object.keys(PROFILES).join(", ")}`,
    );
  }
  const peak = Math.max(1, Math.round((Number(__ENV.PERF_VUS) || profile.vus) * weight));
  const stages = profile.stages(peak);

  return {
    stages,
    // The local edge serves the k3d wildcard cert, which is self-signed — the
    // same reason playwright.config.ts sets ignoreHTTPSErrors.
    insecureSkipTLSVerify: true,
    // Thresholds set the process exit code, which is what makes a run a CI gate
    // without a wrapper script. `abortOnFail` is deliberately NOT set: we want
    // the full curve even after a budget is blown, especially under `stress`.
    thresholds,
    // Response bodies are read (so the timing is honest) but not retained: at a
    // few thousand iterations the product list alone would otherwise dominate
    // the generator's own memory and make it, not the platform, the bottleneck.
    discardResponseBodies: false,
    // Run-level tags: applied to EVERY metric including the custom Trends, which
    // per-request tags cannot reach. `scenario` is what separates browse from
    // checkout series in Prometheus — both export under service.name=k6, so
    // without it the two runs would be indistinguishable there.
    tags: { profile: PROFILE, scenario },
    userAgent: `k6-perf/${PROFILE}`,
    systemTags: SYSTEM_TAGS,
  };
}

// summaryTrailer is printed from every scenario's teardown() so a captured run
// always carries the caveat with it — a co-hosted generator competes with the
// cluster for host CPU, so these are relative regression signals, not capacity
// figures (ADR-0027).
export function summaryTrailer() {
  return [
    "",
    `  target:  ${BASE_URL}`,
    `  profile: ${PROFILE}`,
    "  note:    generator runs on the host and shares CPU with the k3d node —",
    "           read these as a regression signal, not an absolute capacity figure.",
    "",
  ].join("\n");
}
