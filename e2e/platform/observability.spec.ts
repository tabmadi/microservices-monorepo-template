// Observability gauge (ADR-0011), two layers:
//
//  1. Datasource health — the three Grafana datasources resolve and answer. This is
//     the wiring check behind the service-name fix: Grafana, the OTel collector and
//     prod all reach Loki/Tempo/Prometheus at their short in-cluster names, and Loki
//     runs single-tenant so header-less queries don't 401. Driven through the real
//     ops edge with the saved AAL2 operator session (Grafana's HTTP API, no browser).
//
//  2. End-to-end signal correlation — one real checkout, then assert all three
//     signals landed and cross-reference each other: a single trace stitched across
//     orders+catalog+payment (Tempo), log lines carrying that trace_id from every
//     service (Loki), and the RED/domain counters moved (Prometheus). This is the
//     regression gauge for the propagation + log-export + netpol fixes — with any of
//     them broken the trace fragments, the logs lose their trace_id, or the checkout
//     never reaches payment.
import { type APIRequestContext, expect, request, test } from "@playwright/test";
import { OPERATOR_STATE, opsURL } from "../fixtures/env";
import { portForward } from "../fixtures/kube";
import {
  forwardObservability,
  lokiServicesForTrace,
  newTraceparent,
  type ObsForwards,
  promSeriesCount,
  waitForTraceServices,
} from "../fixtures/observability";

const GRAFANA_API = `${opsURL("grafana")}/api/datasources`;

test.describe("grafana datasources", () => {
  for (const name of ["Loki", "Tempo", "Prometheus"]) {
    test(`${name} datasource is healthy behind the operator session`, async () => {
      const ctx: APIRequestContext = await request.newContext({
        ignoreHTTPSErrors: true,
        storageState: OPERATOR_STATE,
      });
      try {
        const ds = await ctx.get(`${GRAFANA_API}/name/${name}`);
        expect(ds.ok(), `${name} datasource is provisioned`).toBeTruthy();
        const { uid } = await ds.json();
        const health = await ctx.get(`${GRAFANA_API}/uid/${uid}/health`);
        expect(health.ok(), `${name} health endpoint reachable`).toBeTruthy();
        expect((await health.json()).status, `${name} reachable from Grafana`).toBe("OK");
      } finally {
        await ctx.dispose();
      }
    });
  }
});

// Network-policy denials (ADR-0011, ADR-0025). Hubble UI shows live drops
// interactively; the metric + dashboard cover what it can't — history and the
// PolicyDropsDetected alert — and are worth their own guard given how often
// silent netpol drops have broken this repo.
//
// Two failure modes are covered, and they are different:
//  - the `hubble-drops` dashboard missing means Grafana's dashboard PROVIDER is
//    misconfigured. Mounting JSON via dashboardsConfigMaps is not enough on its own;
//    without a matching dashboardProviders entry the files sit on disk unregistered
//    and /api/search returns [] (the state this repo was in until 2026-07-20).
//  - no hubble_drop_total series means the ingest path broke: Hubble metrics off in
//    the Cilium values, or the collector's prometheus/hubble scrape not reaching
//    :9965 on its own node.
test.describe("network policy denials", () => {
  let ctx: APIRequestContext;

  test.beforeAll(async () => {
    ctx = await request.newContext({ ignoreHTTPSErrors: true, storageState: OPERATOR_STATE });
  });
  test.afterAll(async () => {
    await ctx?.dispose();
  });

  test("the drops dashboard is provisioned, not just mounted", async () => {
    const res = await ctx.get(`${opsURL("grafana")}/api/search?type=dash-db`);
    expect(res.ok(), "Grafana search API answers").toBeTruthy();
    const uids = ((await res.json()) as { uid: string }[]).map((d) => d.uid);
    expect(uids, "committed dashboards are registered with Grafana").toEqual(
      expect.arrayContaining(["hubble-drops"]),
    );
  });

  test("Hubble drop metrics reach Prometheus with workload labels", async () => {
    const ds = await ctx.get(`${opsURL("grafana")}/api/datasources/name/Prometheus`);
    expect(ds.ok(), "Prometheus datasource is provisioned").toBeTruthy();
    const { uid } = await ds.json();

    const res = await ctx.post(`${opsURL("grafana")}/api/ds/query`, {
      data: {
        from: "now-15m",
        to: "now",
        queries: [
          {
            refId: "A",
            datasource: { type: "prometheus", uid },
            // `sourceContext=workload` renders a combined "<namespace>/<workload>"
            // label, so grouping by it proves the workload context is on.
            expr: "sum by (source, destination) (rate(hubble_drop_total[5m]))",
            instant: true,
          },
        ],
      },
    });
    expect(res.ok(), "Grafana executes the drops query").toBeTruthy();
    const frames = (await res.json()).results?.A?.frames ?? [];
    expect(frames.length, "hubble_drop_total has series (metrics enabled + scraped)").toBeGreaterThan(
      0,
    );
  });
});

// Unified service observability (ADR-0025 POC). The service-detail page mixes six
// signal groups on one screen (SLO/RED, CPU/Memory, Logs, Traces, Profiling). These
// guards cover the prerequisites that helm-template/render checks cannot: the
// dashboards are registered with Grafana, the Pyroscope datasource answers, the
// alert rules are loaded into Prometheus, and each metric family a panel reads
// actually exists in Prometheus. The RED check also pins us to the STABLE otelhttp histogram — the
// hand-rolled, mis-bucketed httpmw metric was removed (ADR-0011), and le="0.5" being
// a real 500ms bucket is what proves we are on the correct one.
test.describe("service observability POC (ADR-0025)", () => {
  let ctx: APIRequestContext;
  let promUid: string;

  test.beforeAll(async () => {
    ctx = await request.newContext({ ignoreHTTPSErrors: true, storageState: OPERATOR_STATE });
    const ds = await ctx.get(`${opsURL("grafana")}/api/datasources/name/Prometheus`);
    promUid = (await ds.json()).uid;
  });
  test.afterAll(async () => {
    await ctx?.dispose();
  });

  // Runs an instant PromQL query through Grafana's datasource proxy and reports
  // whether any series came back (frames are empty when nothing matches).
  async function promHasSeries(expr: string): Promise<boolean> {
    const res = await ctx.post(`${opsURL("grafana")}/api/ds/query`, {
      data: {
        from: "now-24h",
        to: "now",
        queries: [{ refId: "A", datasource: { type: "prometheus", uid: promUid }, expr, instant: true }],
      },
    });
    if (!res.ok()) {
      return false;
    }
    return (((await res.json()).results?.A?.frames ?? []) as unknown[]).length > 0;
  }

  test("every POC dashboard is registered with Grafana", async () => {
    const res = await ctx.get(`${opsURL("grafana")}/api/search?type=dash-db`);
    expect(res.ok(), "Grafana search API answers").toBeTruthy();
    const uids = ((await res.json()) as { uid: string }[]).map((d) => d.uid);
    expect(uids, "overview + detail + applications + components dashboards are provisioned").toEqual(
      expect.arrayContaining(["overview", "service-detail", "applications", "platform-components"]),
    );
  });

  test("Pyroscope datasource is provisioned and healthy", async () => {
    const ds = await ctx.get(`${opsURL("grafana")}/api/datasources/name/Pyroscope`);
    expect(ds.ok(), "Pyroscope datasource is provisioned").toBeTruthy();
    const { uid } = await ds.json();
    const health = await ctx.get(`${opsURL("grafana")}/api/datasources/uid/${uid}/health`);
    expect(health.ok(), "Pyroscope health endpoint reachable").toBeTruthy();
    expect((await health.json()).status, "Pyroscope answers from Grafana").toBe("OK");
  });

  test("kubeletstats CPU/memory series exist (resource panels)", async () => {
    expect(await promHasSeries('k8s_pod_cpu_usage{service_namespace="platform"}')).toBeTruthy();
    expect(await promHasSeries('k8s_pod_memory_working_set_bytes{service_namespace="platform"}')).toBeTruthy();
  });

  test("RED reads the stable otelhttp histogram (real 500ms bucket)", async () => {
    expect(await promHasSeries('http_server_request_duration_seconds_bucket{le="0.5"}')).toBeTruthy();
  });

  // otel-cluster's two jobs. k8s_cluster: the desired/available/restart series
  // the workload-health alerts and the service-detail Health row read — its OTLP
  // push is netpol-gated (prometheus CNP must allow otel-cluster; it silently
  // didn't until 2026-07-23, which is what ClusterStateMetricsAbsent fires on).
  // Exporter scrapes: postgres (CNPG :9187) and Temporal (:9090) land under the
  // canonical service_name identity — each guards its scrape config, the
  // metrics-port ingress rule on the target, and (for temporal) the delete_key
  // that stops the exporter's own service_name label fragmenting the identity.
  test("otel-cluster series exist: cluster state + component exporters", async () => {
    expect(await promHasSeries('k8s_deployment_desired{service_namespace="platform"}')).toBeTruthy();
    expect(await promHasSeries('cnpg_backends_total{service_name="postgres"}')).toBeTruthy();
    expect(await promHasSeries('service_requests_total{service_name="temporal"}')).toBeTruthy();
  });

  // Alerts-as-code (ADR-0011): the rule files under infra/observability/alerts/
  // must actually be LOADED by Prometheus, not just committed. This catches every
  // link in the chain — the prometheus-alerts kustomize ConfigMap, its Argo app,
  // the chart's rule_files + volume mount, and rule-file syntax (Prometheus
  // refuses to load a malformed file).
  test("alert rules are loaded into Prometheus", async () => {
    const res = await ctx.get(
      `${opsURL("grafana")}/api/datasources/proxy/uid/${promUid}/api/v1/rules`,
    );
    expect(res.ok(), "Prometheus rules API answers via the Grafana proxy").toBeTruthy();
    const groups: { rules: { name: string }[] }[] = (await res.json()).data?.groups ?? [];
    const names = groups.flatMap((g) => g.rules.map((r) => r.name));
    expect(names, "committed alert rules are evaluating").toEqual(
      expect.arrayContaining([
        "ServiceHigh5xx",
        "PolicyDropsDetected",
        "DeploymentReplicasUnavailable",
        "ContainerRestartsSpiking",
      ]),
    );
  });

  // Log coverage for PLATFORM workloads (ADR-0011's filelog path). Repo services
  // push logs over OTLP from the SDK, but postgres/temporal/lowdefy/… only write
  // stdout — those reach Loki solely through the collector's logsCollection
  // (filelog) preset. Until 2026-07-23 that receiver was missing and every
  // platform service showed a permanently empty Logs panel on service-detail.
  // Asserting distinct service_name values (24h window — these workloads can be
  // quiet at idle) pins the whole chain: hostPath mount, filelog receiver,
  // container parser, and the k8sattributes service.name inference the dashboard
  // filters on. grafana/loki/tempo appear as "observability": service.name
  // inference prefers app.kubernetes.io/instance (the Helm release) over /name.
  //
  // The collector agent itself is deliberately NOT in this list. Its filelog
  // receiver excludes its own pod
  // (`/var/log/pods/platform_otel-collector*_*/opentelemetry-collector/*.log`,
  // infra/helm/platform/observability) so that a log line about reading a log file
  // does not become a log file to read — the standard feedback-loop guard. Asserting
  // "otel-collector" here made this test permanently red: the label cannot exist by
  // construction, and Loki confirms it is absent over any window while every other
  // name in this list is present. Agent health is covered by its metrics, not by its
  // own stdout.
  test("platform workloads that only log to stdout reach Loki (filelog)", async () => {
    const ds = await ctx.get(`${opsURL("grafana")}/api/datasources/name/Loki`);
    expect(ds.ok(), "Loki datasource is provisioned").toBeTruthy();
    const { uid } = await ds.json();
    const start = `${(Date.now() - 24 * 3600 * 1000) * 1e6}`;
    const res = await ctx.get(
      `${opsURL("grafana")}/api/datasources/proxy/uid/${uid}/loki/api/v1/label/service_name/values?start=${start}`,
    );
    expect(res.ok(), "Loki label API answers via the Grafana proxy").toBeTruthy();
    const services: string[] = (await res.json()).data ?? [];
    expect(services, "stdout-only platform workloads have logs in Loki").toEqual(
      expect.arrayContaining(["postgres", "temporal", "lowdefy", "observability", "otel-cluster"]),
    );
  });
});

// A checkout drives every signal at once. Rather than the browser, this layer hits
// the services east-west through port-forwards with a KNOWN inbound traceparent, so
// the trace id is fixed up front (no search race) and the assertions are
// deterministic. The browser-driven equivalent lives in purchase.spec.ts.
test.describe("end-to-end signal correlation", () => {
  const CATALOG_PORT = 18081;
  const ORDERS_PORT = 18082;
  let stopCatalog: () => void;
  let stopOrders: () => void;
  let obs: ObsForwards;

  test.beforeAll(async () => {
    ({ stop: stopCatalog } = await portForward("catalog-server", CATALOG_PORT, 80));
    ({ stop: stopOrders } = await portForward("orders-server", ORDERS_PORT, 80));
    obs = await forwardObservability();
  });

  test.afterAll(() => {
    stopCatalog?.();
    stopOrders?.();
    obs?.stop();
  });

  test("a checkout emits a stitched trace, correlated logs and metrics @smoke", async () => {
    test.setTimeout(180_000);
    const catalog = `http://127.0.0.1:${CATALOG_PORT}`;
    const orders = `http://127.0.0.1:${ORDERS_PORT}`;

    // Operator-authored product (X-User-Id admin-console holds group:operator, the
    // same subject the admin console writes as — ADR-0012).
    const productRes = await fetch(`${catalog}/products`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-user-id": "admin-console" },
      body: JSON.stringify({ name: `obs-e2e-${Date.now()}`, price_cents: 4200 }),
    });
    expect(productRes.ok, "operator can create a product").toBeTruthy();
    const productId = ((await productRes.json()) as { id: string }).id;

    // Checkout with a known, sampled traceparent → the trace id is fixed.
    const { header, traceId } = newTraceparent();
    const orderRes = await fetch(`${orders}/orders`, {
      method: "POST",
      headers: { "content-type": "application/json", traceparent: header },
      body: JSON.stringify({ product_id: productId, quantity: 2 }),
    });
    expect(orderRes.status, "checkout accepted (202)").toBe(202);
    const orderId = ((await orderRes.json()) as { run_id: string }).run_id;

    // The saga is async: poll the order until it confirms (catalog lookup + payment
    // charge both succeeded — the reachability the netpol fix restored).
    await expect
      .poll(
        async () => {
          const r = await fetch(`${orders}/orders/${orderId}`);
          return ((await r.json()) as { status: string }).status;
        },
        { timeout: 90_000, intervals: [1000, 2000, 3000] },
      )
      .toBe("confirmed");

    // TEMPO: one trace, three services. The cross-service stitch — broken before the
    // global propagator + otelhttp-transport fixes.
    const services = await waitForTraceServices(traceId, ["orders", "catalog", "payment"]);
    expect(services).toEqual(expect.arrayContaining(["orders", "catalog", "payment"]));

    // LOKI: the same trace_id appears in log structured metadata for each service —
    // logs↔traces correlation, broken before the access-log-inside-span reorder and
    // the gRPC log-export fix.
    let logServices: string[] = [];
    await expect
      .poll(
        async () => {
          logServices = await lokiServicesForTrace(traceId);
          return ["orders", "catalog", "payment"].every((s) => logServices.includes(s));
        },
        { timeout: 60_000, intervals: [2000, 3000, 5000] },
      )
      .toBe(true);
    expect(logServices).toEqual(expect.arrayContaining(["orders", "catalog", "payment"]));

    // PROMETHEUS: the domain + RED counters moved. Prometheus escapes OTLP dotted
    // names to the classic underscore form (UnderscoreEscapingWithSuffixes), so the
    // stored series are orders_checkouts_started_total and — for RED — the stable
    // otelhttp histogram's http_server_request_duration_seconds_count (httpmw's
    // hand-rolled http.server.requests counter was removed, ADR-0011).
    await expect
      .poll(async () => await promSeriesCount("orders_checkouts_started_total"), { timeout: 60_000 })
      .toBeGreaterThan(0);
    expect(await promSeriesCount("http_server_request_duration_seconds_count")).toBeGreaterThan(0);
    expect(await promSeriesCount("catalog_products_created_total")).toBeGreaterThan(0);
  });
});
