// Cross-service mutation polling (ADR-0006, ADR-0014). Services that start a
// workflow respond with 202 + a WorkflowHandle (the schema declared in each
// service's openapi.yaml): { id, run_id, status, result_url }. The handle's
// result_url points at the resource's GET endpoint (e.g. /api/orders/<id>), whose
// payload carries the terminal domain status. This helper polls that URL until the
// resource reaches a terminal state.
import type { components } from "@/sdks/orders";

export type WorkflowHandle = components["schemas"]["WorkflowHandle"];

// The terminal-state shape shared by the resources a workflow settles (orders,
// charges): a domain status string. "pending"/"running" are non-terminal.
export type TerminalResource = { status: string };

const TERMINAL = new Set(["confirmed", "completed", "failed", "cancelled", "settled", "refunded"]);

type PollOpts = {
  intervalMs?: number;
  timeoutMs?: number;
  signal?: AbortSignal;
};

// pollWorkflow GETs the handle's result_url until the resource's status is terminal
// (or the timeout elapses), then returns that resource. It resolves on the first
// terminal status regardless of success/failure — the caller decides how to render
// "failed" vs "confirmed" (a failed charge is still a completed poll, not an error).
export async function pollWorkflow<T extends TerminalResource>(
  handle: WorkflowHandle,
  { intervalMs = 1000, timeoutMs = 60_000, signal }: PollOpts = {},
): Promise<T> {
  if (!handle.result_url) {
    throw new Error("workflow handle has no result_url to poll");
  }
  const deadline = Date.now() + timeoutMs;
  // biome-ignore lint/suspicious/noUnnecessaryConditions: poll loop exits via return/throw below
  while (true) {
    if (signal?.aborted) {
      throw new Error("aborted");
    }
    // biome-ignore lint/performance/noAwaitInLoops: workflow polling is intentionally sequential
    const res = await fetch(handle.result_url, { cache: "no-store", signal });
    if (res.ok) {
      const body = (await res.json()) as T;
      if (TERMINAL.has(body.status)) {
        return body;
      }
    }
    if (Date.now() > deadline) {
      throw new Error("workflow poll timed out before reaching a terminal status");
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}
