// Shared response assertions for k6 scenarios (ADR-0027).
//
// A k6 `check` records a pass/fail rate but — unlike a test assertion — does NOT
// fail the run on its own. That is deliberate here: under load some failures are
// the finding, not an error. What fails a run is a threshold in the scenario's
// options, and every helper below feeds the `checks` rate that those thresholds
// can be written against.
import { check } from "k6";

// expectStatus asserts the response code and that a body came back at all. The
// body check catches the specific local failure mode where Traefik answers with
// an empty 200 because an upstream went away mid-run.
export function expectStatus(res, want, name) {
  return check(res, {
    [`${name}: status ${want}`]: (r) => r.status === want,
    [`${name}: body present`]: (r) => r.body !== null && r.body.length > 0,
  });
}

// expectJSON asserts a JSON body and hands the parsed value to a predicate.
// Parsing is guarded: an RFC 7807 problem document (libs/go/apierr) and an
// HTML error page from the edge both arrive as "not the JSON you expected", and
// a bare JSON.parse would abort the VU's iteration instead of recording a check.
export function expectJSON(res, name, predicate) {
  let parsed = null;
  try {
    parsed = res.json();
  } catch {
    parsed = null;
  }
  const ok = check(res, {
    [`${name}: parses as JSON`]: () => parsed !== null,
    [`${name}: shape valid`]: () => parsed !== null && predicate(parsed),
  });
  return { ok, body: parsed };
}
