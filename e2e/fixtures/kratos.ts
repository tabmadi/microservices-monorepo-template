// Browser helpers that drive the REAL self-service auth UI (apps/frontend
// KratosFlow): native Kratos UI nodes rendered as a form that POSTs back to Kratos.
// No SDK, no API shortcut — the e2e logs in the way a human would (ADR-0018: the
// rendered, authenticated UI is the gauge).
//
// Navigation goes through Kratos's `*/browser` init endpoints: Kratos mints the
// flow and 303s to the UI page WITH ?flow, so KratosFlow renders the form directly
// instead of client-redirecting (which would abort a plain page.goto to the UI).
import { type Page, expect } from "@playwright/test";
import { authenticator } from "otplib";
import { BASE_URL } from "./env";

const init = (flow: string, query = "") => `${BASE_URL}/auth/self-service/${flow}/browser${query}`;

// The password-method submit button (KratosFlow renders submit nodes as
// <button name="method" value="...">). Same shape for the totp second factor.
const submitFor = (method: string) => `button[name="method"][value="${method}"]`;

// Navigate to a Kratos */browser init endpoint, which 303s to the UI page with
// ?flow. That server redirect can surface as ERR_ABORTED on the goto; it is
// benign — the caller waits for the rendered form's input next. Tolerate it.
async function gotoFlow(page: Page, url: string): Promise<void> {
  await page.goto(url, { waitUntil: "domcontentloaded" }).catch((err: unknown) => {
    if (!String(err).includes("ERR_ABORTED")) {
      throw err;
    }
  });
}

async function notOnLogin(page: Page): Promise<void> {
  await expect(page).not.toHaveURL(/\/auth\/login/, { timeout: 20_000 });
}

// Wait until the Kratos session cookie is actually set in the context. notOnLogin
// only proves the URL left the login page; a subsequent flow init (e.g. settings)
// can otherwise race ahead of the Set-Cookie and bounce to the return URL.
async function waitForSession(page: Page): Promise<void> {
  await expect
    .poll(async () => (await page.context().cookies()).some((c) => c.name === "ory_kratos_session"), {
      timeout: 15_000,
    })
    .toBe(true);
}

// passwordLogin completes first-factor (AAL1) login through the rendered form.
export async function passwordLogin(page: Page, email: string, password: string): Promise<void> {
  await gotoFlow(page, init("login"));
  await page.locator('input[name="identifier"]').waitFor({ state: "visible", timeout: 20_000 });
  await page.fill('input[name="identifier"]', email);
  await page.fill('input[name="password"]', password);
  await page.click(submitFor("password"));
  await notOnLogin(page);
  await waitForSession(page);
}

// register completes a self-service registration through the rendered form. This is
// the ONLY path that fires the registration `after` web_hook
// (infra/auth/kratos/values.yaml) — identities created through the Kratos admin API
// (fixtures/bootstrap.ts, scripts/ops-grant.sh) skip self-service flows entirely, so
// they never get a personal org.
//
// Registration is TWO-STEP: the first screen carries the identity traits and a
// `profile` submit, and emits no password node at all; only after it does Kratos
// render the credential screen (traits ride along as hidden nodes). Driving it as a
// single form silently hangs on a password field that is not there yet.
//
// No `session` hook is configured after registration, so this does NOT leave an
// authenticated session; it only proves the identity was created.
export async function register(page: Page, email: string, password: string): Promise<void> {
  await gotoFlow(page, init("registration"));
  await page.locator('input[name="traits.email"]').waitFor({ state: "visible", timeout: 20_000 });
  await page.fill('input[name="traits.email"]', email);
  await page.click(submitFor("profile"));

  await page.locator('input[name="password"]').waitFor({ state: "visible", timeout: 20_000 });
  await page.fill('input[name="password"]', password);
  await page.click(submitFor("password"));
  // Kratos re-renders the register form with the message on any failure — including
  // a rejected password policy and, because the orgs web_hook is blocking
  // (`ignore: false`), a failed personal-org enqueue. Leaving the form is therefore
  // the success signal.
  await expect(page).not.toHaveURL(/\/auth\/register/, { timeout: 30_000 });
}

// registerExpectingRejection drives the same two-step form as `register` but for
// the opposite outcome: the password policy REFUSES the credential, so Kratos
// re-renders the flow with the reason attached instead of leaving it. Returns the
// rendered text so the caller can pin WHICH rule fired — a test that only asserted
// "rejected" would pass just as happily when the password was refused for being
// too short, which is exactly how a dead breach check hides.
export async function registerExpectingRejection(
  page: Page,
  email: string,
  password: string,
): Promise<string> {
  await gotoFlow(page, init("registration"));
  await page.locator('input[name="traits.email"]').waitFor({ state: "visible", timeout: 20_000 });
  await page.fill('input[name="traits.email"]', email);
  await page.click(submitFor("profile"));

  await page.locator('input[name="password"]').waitFor({ state: "visible", timeout: 20_000 });
  await page.fill('input[name="password"]', password);
  await page.click(submitFor("password"));

  // Staying on /auth/register is the rejection signal — the inverse of the
  // "left the form" success signal `register` waits for. The re-rendered credential
  // step carries the message on the password node (KratosFlow renders node messages
  // as the input's hint), so read the whole page rather than pinning that markup.
  //
  // Leaving the form here means the policy ACCEPTED the credential. Say so in the
  // message: the raw diff ("expected /auth/register, got /") reads like a routing
  // bug rather than what it is.
  await expect(
    page,
    "password was ACCEPTED — the policy that should have refused it did not fire",
  ).toHaveURL(/\/auth\/register/, { timeout: 30_000 });
  await page.locator('input[name="password"]').waitFor({ state: "visible", timeout: 20_000 });
  return page.locator("body").innerText();
}

// operatorLogin performs a complete operator login from a fresh context: first
// factor (password), then — because an operator has TOTP enrolled — the second
// factor on the same /auth/login flow, answered with the known secret. Ends with
// an AAL2 session. (passwordLogin alone assumes a password-only identity.)
export async function operatorLogin(
  page: Page,
  email: string,
  password: string,
  secret: string,
): Promise<void> {
  await gotoFlow(page, init("login"));
  await page.locator('input[name="identifier"]').waitFor({ state: "visible", timeout: 20_000 });
  await page.fill('input[name="identifier"]', email);
  await page.fill('input[name="password"]', password);
  await page.click(submitFor("password"));
  // required_aal=highest_available steps the flow up to the totp prompt in place.
  const totp = page.locator('input[name="totp_code"]');
  const prompted = await totp
    .waitFor({ state: "visible", timeout: 15_000 })
    .then(() => true)
    .catch(() => false);
  if (prompted) {
    await totp.fill(authenticator.generate(secret));
    await page.click(submitFor("totp"));
  }
  await notOnLogin(page);
  await waitForSession(page);
}

// enrolTotp enrols a TOTP second factor via the settings flow, reading the secret
// Kratos generates (rendered as the font-mono text node) and verifying a code.
// Returns the secret so an AAL2 re-login can be driven deterministically.
export async function enrolTotp(page: Page): Promise<string> {
  const secretNode = page.locator("p.font-mono").first();
  // Re-init if the flow ever bounces to the return URL before the form renders.
  await expect(async () => {
    await gotoFlow(page, init("settings"));
    await expect(secretNode).toBeVisible({ timeout: 8_000 });
  }).toPass({ timeout: 40_000 });
  const secret = (await secretNode.innerText()).replace(/\s+/g, "");
  await page.fill('input[name="totp_code"]', authenticator.generate(secret));
  await page.click(submitFor("totp"));
  // Settings reloads with the factor enrolled; the secret node disappears.
  await expect(secretNode).toBeHidden({ timeout: 20_000 });
  return secret;
}

// ensureAal2 guarantees the session is AAL2. Completing TOTP enrolment in a
// privileged settings flow already elevates the session, so the ?aal=aal2 login
// usually finds nothing to step up and redirects away; only when a second factor
// is actually demanded do we answer the totp prompt with the known secret.
export async function ensureAal2(page: Page, secret: string): Promise<void> {
  await gotoFlow(page, init("login", "?aal=aal2"));
  const totp = page.locator('input[name="totp_code"]');
  const prompted = await totp
    .waitFor({ state: "visible", timeout: 8_000 })
    .then(() => true)
    .catch(() => false);
  if (prompted) {
    await totp.fill(authenticator.generate(secret));
    await page.click(submitFor("totp"));
  }
  await notOnLogin(page);
}
