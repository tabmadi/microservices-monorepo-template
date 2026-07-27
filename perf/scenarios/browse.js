// Read-path load: the catalog browse journey (ADR-0027).
//
//   GET /api/products        — the list, the query every storefront page makes
//   GET /api/products/{id}   — a detail read, indexed single-row lookup
//
// Driven through the edge, so each request pays Traefik routing + the Oathkeeper
// forward-auth hop (ADR-0009) before catalog ever sees it. Both operations are
// unauthenticated by design (catalog gates only writes — services/catalog
// handlers.requireOperator), so this scenario needs no session and its numbers
// are not distorted by login cost.
//
// What it is for: this path is cheap per request, so it saturates the EDGE and
// the Postgres connection pool long before it saturates catalog itself. That is
// the ceiling it exists to find.
//
// NOTE on what seeding does and does not change here. `ListProducts` is
// `order by created_at desc limit 100` (services/catalog/.../queries/products.sql),
// so the RESPONSE never grows past 100 rows no matter how many products exist.
// Seeding still changes the test, but on the server side only: there is no index
// on `created_at`, so every list request sorts the whole table to find its top
// 100. That cost scales with the row count while the response size does not —
// which is exactly the kind of thing a load test is supposed to surface, and why
// the seeded row count must be recorded alongside any latency number.

import { sleep } from "k6";
import http from "k6/http";
import { Trend } from "k6/metrics";
import { expectJSON, expectStatus } from "../lib/checks.js";
import { API, options as buildOptions, summaryTrailer } from "../lib/config.js";

// Rows the list endpoint actually returned at the start of the run. Emitted as a
// metric so a captured result carries its own context. Because of the `limit 100`
// above this saturates at 100 and is NOT the table size — it is the page size,
// and its job is to tell you whether the list response was full (server sorting a
// big table) or short (a nearly empty one).
const pageSize = new Trend("catalog_page_size");

export const options = buildOptions("browse", 1, {
  // Budgets, not SLOs (ADR-0027). Generous enough that a green run means "no
  // regression", not "indistinguishable from idle".
  http_req_failed: ["rate<0.01"],
  "http_req_duration{endpoint:list_products}": ["p(95)<800"],
  "http_req_duration{endpoint:get_product}": ["p(95)<400"],
  checks: ["rate>0.99"],
});

// setup runs once, before any VU. It resolves the product ids the VUs will read
// and fails the whole run early if the catalog is empty — otherwise every
// iteration would 404 and the run would report a beautifully fast error rate.
export function setup() {
  const res = http.get(`${API}/products`, { tags: { endpoint: "list_products" } });
  if (res.status !== 200) {
    throw new Error(`catalog unreachable at ${API}/products — HTTP ${res.status}`);
  }
  const products = res.json();
  if (!Array.isArray(products) || products.length === 0) {
    throw new Error("catalog is empty — run `mise run perf:seed` first, or this measures 404s");
  }
  return { ids: products.map((p) => p.id), size: products.length };
}

export default function browse(data) {
  pageSize.add(data.size);

  // 1. The list page.
  const list = http.get(`${API}/products`, {
    tags: { endpoint: "list_products" },
  });
  expectStatus(list, 200, "list products");

  // Think time. Without it a VU is a tight loop, which measures how fast one
  // connection can spin rather than how the system behaves under N users.
  sleep(0.5 + Math.random());

  // 2. A detail page for a random product from the list.
  const id = data.ids[Math.floor(Math.random() * data.ids.length)];
  const detail = http.get(`${API}/products/${id}`, {
    tags: { endpoint: "get_product" },
  });
  if (expectStatus(detail, 200, "get product")) {
    expectJSON(detail, "get product", (p) => p.id === id && typeof p.price_cents === "number");
  }

  sleep(0.5 + Math.random());
}

// teardown, not handleSummary: defining handleSummary REPLACES k6's built-in
// summary table, and hand-rolling that table is either a pile of formatting code
// or a remote jslib import (a supply-chain dependency for cosmetics). Printing
// the caveat here leaves the real summary intact directly below it.
export function teardown(data) {
  console.log(
    `browse — list endpoint returned ${data.ids.length} rows (limit 100)${summaryTrailer()}`,
  );
}
