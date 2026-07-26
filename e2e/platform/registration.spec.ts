// The registration → personal-org flow (ADR-0010, ADR-0006). Kratos owns identities;
// `orgs` owns tenancy, and the two are joined by exactly one wire: the blocking
// `after` web_hook on the self-service registration flow
// (infra/auth/kratos/values.yaml) → POST /identity-created → the RegisterUser
// Temporal workflow → personal org + admin membership + the OpenFGA `org#admin`
// tuple.
//
// This is the gauge for a seam with no unit-test equivalent — it spans Kratos, the
// edge, the orgs server, Temporal, the orgs worker and OpenFGA, and every one of
// them has to be up for an org to appear. It also pins the boundary that is easy to
// misread: identities created through the Kratos ADMIN API (fixtures/bootstrap.ts,
// scripts/ops-grant.sh) do NOT run self-service flows, so they get no org. Seeing
// seeded identities with an empty orgs list is correct; seeing a *registered* user
// with no org is the regression this catches.
import { expect, test } from "@playwright/test";
import { OPERATOR_STATE, opsURL } from "../fixtures/env";
import { register, registerExpectingRejection } from "../fixtures/kratos";
import { portForward } from "../fixtures/kube";

const KRATOS_ADMIN = "http://127.0.0.1:4434";

// Unique per run: Kratos enforces email uniqueness globally.
const EMAIL = `signup-${Date.now()}@e2e.localtest.me`;

// The personal org is named generically ("Personal workspace"), NOT by the email:
// an org is a tenant whose name is shown to every member the user later invites, so
// an email there would leak PII (activities.CreatePersonalOrgActivity, ADR-0023).
// The registrant's assertable link to their org is therefore the OpenFGA admin
// tuple (org:<id>#admin@user:<id>), which is also dual-write leg 2 — the exact seam
// this test guards. Local forward port 18080 (not 8080: k3d maps host 8080 to the
// edge); the key is the cluster:full preshared key.
const PERSONAL_ORG_NAME = "Personal workspace";
const OPENFGA_LOCAL_PORT = Number(process.env.OPENFGA_LOCAL_PORT ?? 18080);
const OPENFGA_TOKEN = process.env.OPENFGA_TOKEN ?? "localdevkey";

// kratosIdFor resolves the Kratos id for a registered email (the authz subject).
async function kratosIdFor(email: string): Promise<string | null> {
  const res = await fetch(
    `${KRATOS_ADMIN}/admin/identities?credentials_identifier=${encodeURIComponent(email)}`,
  );
  if (!res.ok) {
    return null;
  }
  const list = (await res.json()) as Array<{ id: string; traits?: { email?: string } }>;
  return list.find((i) => i.traits?.email === email)?.id ?? null;
}

// adminOrgIds returns the orgs on which `user:<id>` holds `admin` in OpenFGA — the
// ReBAC side of the registration dual-write (model.fga). Assumes a port-forward to
// the OpenFGA HTTP API is already up on OPENFGA_LOCAL_PORT.
async function adminOrgIds(identityId: string): Promise<string[]> {
  const base = `http://127.0.0.1:${OPENFGA_LOCAL_PORT}`;
  const headers = { authorization: `Bearer ${OPENFGA_TOKEN}`, "content-type": "application/json" };
  const stores = (await (await fetch(`${base}/stores`, { headers })).json()) as {
    stores?: { id: string; name: string }[];
  };
  const sid = stores.stores?.find((s) => s.name === "platform")?.id;
  if (!sid) {
    throw new Error("openfga store 'platform' not found — has the seed Job run?");
  }
  const res = await fetch(`${base}/stores/${sid}/list-objects`, {
    method: "POST",
    headers,
    body: JSON.stringify({ type: "org", relation: "admin", user: `user:${identityId}` }),
  });
  if (!res.ok) {
    throw new Error(`openfga list-objects failed: ${res.status} ${await res.text()}`);
  }
  const body = (await res.json()) as { objects?: string[] };
  return (body.objects ?? []).map((o) => o.replace(/^org:/, ""));
}

// Unlike the admin import path used by the bootstrap fixture, self-service
// registration DOES enforce the password policy (haveibeenpwned, min_password_length
// 12, identifier_similarity_check). Keep it long, unbreached, and dissimilar to the
// address — a policy rejection would fail as "no org appeared" and read as an orgs
// bug rather than a bad fixture.
const PASSWORD = "Tr0ubadour-Fjord-Lantern-9!";

test.describe("self-service registration", () => {
  // The assertion runs as the operator: the orgs changelist is an ops dashboard.
  test.use({ storageState: OPERATOR_STATE });

  // The identity outlives the org cleanup below, so remove it directly through the
  // admin API — same teardown shape as the createOperator suite in admin.spec.ts.
  test.afterAll(async () => {
    const pf = await portForward("ory-kratos-admin", 4434, 80);
    try {
      const res = await fetch(
        `${KRATOS_ADMIN}/admin/identities?credentials_identifier=${encodeURIComponent(EMAIL)}`,
      );
      if (!res.ok) return;
      const list = (await res.json()) as Array<{ id: string; traits?: { email?: string } }>;
      const hit = list.find((i) => i.traits?.email === EMAIL);
      if (hit) {
        await fetch(`${KRATOS_ADMIN}/admin/identities/${hit.id}`, { method: "DELETE" });
      }
    } finally {
      pf.stop();
    }
  });

  test("registering a new identity creates its personal org @smoke", async ({ browser, page }) => {
    // Sign up from a clean, anonymous context — the way a human would. `storageState:
    // undefined` is load-bearing, not decoration: browser.newContext() INHERITS the
    // describe-level test.use({ storageState }), so without the override this context
    // carries the operator's ory_kratos_session, and Kratos bounces an already
    // authenticated visitor off the registration flow to the landing page — the form
    // never renders and the failure reads as a missing field.
    const anon = await browser.newContext({ ignoreHTTPSErrors: true, storageState: undefined });
    try {
      await register(await anon.newPage(), EMAIL, PASSWORD);
    } finally {
      await anon.close();
    }

    // Resolve the registrant's Kratos id — the authz subject `user:<id>`.
    const kratosPf = await portForward("ory-kratos-admin", 4434, 80);
    let identityId: string | null;
    try {
      identityId = await kratosIdFor(EMAIL);
    } finally {
      kratosPf.stop();
    }
    expect(identityId, "registered identity must exist in Kratos").toBeTruthy();

    // The org is eventually-consistent: the blocking web_hook only ENQUEUES
    // RegisterUser; cmd/worker runs the two dual-write legs (app-DB org + the OpenFGA
    // org#admin tuple) out of band. Poll the authz plane until the new identity
    // admins exactly one org. A timeout means the workflow never completed (worker
    // down, or a failed OpenFGA leg) — the regression this test guards; a failed
    // enqueue is blocking and would already have failed `register` above.
    const fgaPf = await portForward("openfga", OPENFGA_LOCAL_PORT, 8080);
    let orgId = "";
    try {
      await expect(async () => {
        const ids = await adminOrgIds(identityId as string);
        expect(ids).toHaveLength(1);
        orgId = ids[0];
      }).toPass({ timeout: 60_000 });
    } finally {
      fgaPf.stop();
    }

    // Acceptance gauge (ADR-0018): the new org renders in the admin console, addressed
    // by id (its name is the generic PERSONAL_ORG_NAME, shared across registrants).
    // Clean it up through the console: not just tidiness — the changelist grid
    // paginates at 20 rows client-side (orgs.yaml), so a leftover row per run would
    // eventually push new orgs off the first page.
    await page.goto(`${opsURL("lowdefy")}/orgs_edit?id=${orgId}`);
    const del = page.getByRole("button", { name: "Delete", exact: true });
    await expect(del).toBeVisible({ timeout: 15_000 });
    await del.click();
    await expect(page).toHaveURL(/\/orgs$/, { timeout: 15_000 });
  });
});

// The password policy is enforced by Kratos config that is INJECTED into the chart
// (`infra/auth/kratos/values.yaml` → Helm `--set-file`, ADR-0010). If that injection
// ever breaks, Kratos falls back to its own defaults and the platform silently
// accepts weaker passwords than the ADR claims — a config-delivery failure with no
// unit-test equivalent, which is why this is an e2e.
//
// This used to assert the HaveIBeenPwned breach check instead. ADR-0010 turned that
// check off by default (it needs world egress, and Kratos' `ignore_network_errors`
// makes an unreachable HIBP accept the password silently), so the assertion moved to
// the rule that is always on. If you re-enable the breach check for an environment,
// restore the breached-password test alongside it — `passwordpassword` is the useful
// fixture: 16 chars, so it clears the length rule, and dissimilar to the identifier,
// so only the breach check can reject it.
test.describe("password policy", () => {
  // Register anonymously. Explicit, not inherited: this describe is a sibling of
  // the operator-scoped one above, and an authenticated visitor is bounced off the
  // registration flow entirely (see the note on the test above).
  test.use({ storageState: undefined });

  const WEAK_EMAIL = `weak-${Date.now()}@e2e.localtest.me`;

  // 9 chars: under min_password_length (12) and dissimilar to the identifier, so
  // the length rule is the only one that can reject it — which makes the assertion
  // below specific rather than "something said no".
  const WEAK_PASSWORD = "Fjord-9Ln";

  test("a password under the length policy is refused and creates no identity @smoke", async ({
    page,
  }) => {
    const rendered = await registerExpectingRejection(page, WEAK_EMAIL, WEAK_PASSWORD);

    // Pin the REASON, not just the refusal, so this stays green only while the
    // length rule is what fired.
    expect(rendered, "rejection must name the length rule, not another rule").toMatch(
      /at least 12 characters|too short/i,
    );

    // The security assertion proper: no identity exists.
    const pf = await portForward("ory-kratos-admin", 4434, 80);
    try {
      expect(
        await kratosIdFor(WEAK_EMAIL),
        "a password under the length policy must not create an identity",
      ).toBeNull();
    } finally {
      pf.stop();
    }
  });
});
