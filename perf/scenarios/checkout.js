// Write-path load: the checkout saga (ADR-0027).
//
//   POST /api/orders          — starts the Checkout Temporal workflow (ADR-0006)
//   GET  /api/orders/{id} …   — polled until the saga reaches a terminal status
//
// This is the expensive path and the interesting one. A single iteration touches
// the edge, orders, Postgres, the Temporal frontend/history/matching services,
// the orders worker, and — inside the workflow — catalog and payment. It
// therefore finds a completely different ceiling from browse.js: not requests
// per second, but WORKFLOW THROUGHPUT. The number to watch is not
// `http_req_duration` on the POST (which returns 202 as soon as the workflow is
// started) but `checkout_settle`, the wall time to a terminal order.
//
// The gap between those two is the whole point: an async API stays fast under
// load long after the work behind it has fallen hours behind. Measuring only the
// synchronous response would report a healthy system while the queue explodes.

import { sleep } from "k6";
import http from "k6/http";
import { Rate, Trend } from "k6/metrics";
import { expectJSON, expectStatus } from "../lib/checks.js";
import { API, options as buildOptions, PERF_PREFIX, summaryTrailer } from "../lib/config.js";

// Wall time from "checkout accepted" to "order reached a terminal status". This
// is the saga's real latency and the metric a capacity decision reads.
const settle = new Trend("checkout_settle", true);
// Share of checkouts that reached `confirmed` rather than failing or timing out.
const confirmed = new Rate("checkout_confirmed");
// Share that were still non-terminal when we stopped polling — the backlog
// signal. This rising while `settle` stays flat means the workers are keeping up
// with some checkouts and starving others, which an average would hide.
const timedOut = new Rate("checkout_timeout");

// How long a single checkout is given to settle, and how often it is polled.
// Polling is itself load on the edge, so the interval is deliberately not tight.
const SETTLE_TIMEOUT_MS = 60_000;
const POLL_INTERVAL_S = 1;
const TERMINAL = ["confirmed", "failed", "cancelled"];

// weight 0.25: a checkout costs far more than a product read, so the same
// profile name means a quarter of the VUs here. Without this, `stress` would
// bury Temporal while browse.js was still warming up, and the two runs would not
// be comparable.
export const options = buildOptions("checkout", 0.25, {
  "http_req_failed{endpoint:create_order}": ["rate<0.01"],
  // The synchronous half: how fast the API accepts work.
  "http_req_duration{endpoint:create_order}": ["p(95)<1500"],
  // The asynchronous half: how fast the platform actually does it.
  checkout_settle: ["p(95)<30000"],
  checkout_confirmed: ["rate>0.95"],
  checkout_timeout: ["rate<0.05"],
});

// setup resolves one product to buy. Every VU checks out the same product on
// purpose: it holds the catalog side constant so the measurement is of the saga,
// and it puts every iteration in contention for the same row — which is where a
// write-path lock problem would show up if there were one.
export function setup() {
  const res = http.get(`${API}/products`, { tags: { endpoint: "list_products" } });
  if (res.status !== 200) {
    throw new Error(`catalog unreachable at ${API}/products — HTTP ${res.status}`);
  }
  const products = res.json();
  if (!Array.isArray(products) || products.length === 0) {
    throw new Error("catalog is empty — run `mise run perf:seed` first");
  }
  // Prefer a product this suite seeded, so a load run does not depend on
  // whatever the e2e suite happens to have left behind.
  const seeded = products.filter((p) => String(p.name).startsWith(PERF_PREFIX));
  const [chosen] = seeded.length > 0 ? seeded : products;
  return { productId: chosen.id, productName: chosen.name };
}

export default function checkout(data) {
  // 1. Start the saga.
  const started = Date.now();
  const res = http.post(
    `${API}/orders`,
    JSON.stringify({ product_id: data.productId, quantity: 1 }),
    {
      headers: { "Content-Type": "application/json" },
      tags: { endpoint: "create_order" },
    },
  );
  // 202 Accepted, not 201: the order exists but the saga has not run yet.
  if (!expectStatus(res, 202, "create order")) {
    confirmed.add(false);
    return;
  }
  const { ok, body } = expectJSON(res, "create order", (h) => typeof h.run_id === "string");
  if (!ok) {
    confirmed.add(false);
    return;
  }
  // The handle's run_id is the order id (services/orders handlers.Checkout).
  const orderId = body.run_id;

  // 2. Poll to a terminal status.
  let status = "pending";
  while (Date.now() - started < SETTLE_TIMEOUT_MS) {
    sleep(POLL_INTERVAL_S);
    const poll = http.get(`${API}/orders/${orderId}`, {
      tags: { endpoint: "get_order" },
    });
    // A non-200 poll is not a failure of the checkout — the order may simply not
    // be readable yet. Keep waiting; the timeout above is the real verdict.
    if (poll.status === 200) {
      status = poll.json()?.status ?? status;
      if (TERMINAL.includes(status)) {
        break;
      }
    }
  }

  const reachedTerminal = TERMINAL.includes(status);
  timedOut.add(!reachedTerminal);
  confirmed.add(status === "confirmed");
  // Only record settle time for checkouts that actually settled: folding the
  // 60s timeout into the Trend would make the p95 a measure of the timeout
  // constant rather than of the platform.
  if (reachedTerminal) {
    settle.add(Date.now() - started);
  }

  sleep(1);
}

export function teardown(data) {
  console.log(`checkout — bought "${data.productName}"${summaryTrailer()}`);
}
