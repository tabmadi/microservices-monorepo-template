#!/usr/bin/env bash
# Auth single-source lint. Two rules, one subject: authentication is defined in
# exactly one place and enforced by the real stack.
#
#  1. The auth CONFIG lives exactly once, in the canonical infra/auth tree, and is
#     injected into the Ory umbrella chart at install time (Helm `-f` overlays +
#     `--set-file`; ArgoCD valueFiles + fileParameters). This guard fails CI if any
#     of it is re-inlined back into the chart values, which is how the copies
#     silently diverged before.
#  2. The frontend carries no development-only auth CODE (ADR-0029). Local work
#     against mocked data still logs in for real via the `edge` profile, so a
#     session bypass, a synthetic session object, or a NODE_ENV branch in the app's
#     auth path has no reason to exist — and principle 9 predicts what happens to
#     one that does.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

VALUES="infra/helm/platform/ory/values.yaml"
fail=0

# Markers that only appear when kratos/oathkeeper config or the string artefacts
# have been inlined into the chart values. The legitimate file carries only the
# `enabled` flags and the (deferred) Hydra block.
PATTERNS='accessRules|identitySchemas|default_schema_id|authenticators:|access_rules:|selfservice:|cookie_session|ory_kratos_session'
# Match with original line numbers, then drop comment lines (the header doc-pointers
# legitimately name these keys) — a comment is `<n>:<spaces>#…`.
if hits=$(grep -nEi "$PATTERNS" "$VALUES" 2>/dev/null | grep -vE '^[0-9]+:\s*#'); then
  echo "✗ auth config re-inlined into $VALUES — it must live only in infra/auth/*:" >&2
  echo "$hits" >&2
  fail=1
fi

# The canonical artefacts must exist (the injection points reference them).
for f in \
  infra/auth/kratos/values.yaml \
  infra/auth/oathkeeper/values.yaml \
  infra/auth/oathkeeper/access-rules.json \
  infra/auth/kratos/identity-schemas/user.v1.json; do
  if [ ! -f "$f" ]; then
    echo "✗ missing canonical auth artefact: $f" >&2
    fail=1
  fi
done

# --- 2. No development-only auth code in the frontend (ADR-0029) -------------
# Scope is the app's authn gate and its auth library — the two places a bypass is
# actually reachable from. Comments are dropped so this file's own prose, and the
# ADR pointers in the app, do not trip it.
AUTH_PATHS=(apps/frontend/src/proxy.ts apps/frontend/src/lib/auth)
# An environment-conditional branch is only a finding when it is conditioning the
# SESSION — proxy.ts legitimately relaxes the CSP for `next dev`, which grants
# nothing. So NODE_ENV counts only alongside an auth word on the same line.
BYPASS='DEV_AUTH|AUTH_BYPASS|BYPASS_AUTH|dev-?auth|auth-?bypass|fake[-_ ]?session|NODE_ENV.*(session|auth|identity|bypass)|(session|auth|identity|bypass).*NODE_ENV'
for p in "${AUTH_PATHS[@]}"; do
  [ -e "$p" ] || continue
  if hits=$(grep -rniE "$BYPASS" "$p" | grep -vE '^[^:]+:[0-9]+:\s*(//|\*|/\*)'); then
    echo "✗ development-only auth code in $p — the frontend has ONE auth path and it is the production one (ADR-0029):" >&2
    echo "$hits" >&2
    echo "  To develop against mocked data while logged in, use: mise run cluster:edge" >&2
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "✓ auth single-source: no inline config in $VALUES, no dev-only auth code in the frontend"
fi
exit "$fail"
