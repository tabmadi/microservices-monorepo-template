// Server component fetches via the server-only fetcher (ADR-0014). Direct
// fetch() to service URLs is lint-forbidden; this path goes through the
// generated catalog SDK once `mise run gen:openapi` has produced it.
//
// import type { paths } from "@/sdks/catalog";
// const catalog = await createServerClient<paths>();
// const { data } = await catalog.GET("/products");

import { createServerClient } from "@/lib/server-fetch/server";
// React Aria's Table must build its collection client-side, so the interactive
// table is a client child; this RSC just fetches and hands it the data.
import type { paths } from "@/sdks/catalog";
import { panel } from "@/strings/panel";
import { ProductsTable } from "./products-table";

export default async function Products() {
  const catalog = await createServerClient<paths>();
  const { data } = await catalog.GET("/products");
  const products = data ?? [];

  return (
    <main className="mx-auto max-w-3xl p-6">
      <h1 className="text-2xl font-semibold">{panel.products.title}</h1>
      <ProductsTable products={products} />
    </main>
  );
}
