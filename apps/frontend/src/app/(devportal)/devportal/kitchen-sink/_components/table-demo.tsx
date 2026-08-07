"use client";

// React Aria's Table builds its collection by introspecting Row/Cell children,
// which only works when they're created client-side — a Server Component would
// hand it opaque client references. So the Table demo lives in this client child.
import { Table } from "@/components/application/table/table";

const rows = [
  { id: "1", name: "Widget", price: "$9.99" },
  { id: "2", name: "Gadget", price: "$19.99" },
];

export function TableDemo() {
  return (
    <Table aria-label="Sample products" className="w-full">
      <Table.Header>
        <Table.Head id="name" isRowHeader label="Product" />
        <Table.Head id="price" label="Price" />
      </Table.Header>
      <Table.Body>
        {rows.map((row) => (
          <Table.Row key={row.id} id={row.id}>
            <Table.Cell className="font-medium text-primary">{row.name}</Table.Cell>
            <Table.Cell className="tabular-nums">{row.price}</Table.Cell>
          </Table.Row>
        ))}
      </Table.Body>
    </Table>
  );
}
