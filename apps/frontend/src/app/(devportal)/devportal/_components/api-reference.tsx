"use client";

import { ApiReferenceReact } from "@scalar/api-reference-react";
// Scalar ships its stylesheet as a separate export; the JS wrapper does not import
// it, so without this the reference renders unstyled. Bundled by Next → served
// same-origin (style-src 'self'), no CDN.
import "@scalar/api-reference-react/style.css";

// Scalar mounts a Vue app into a ref on the client (ADR-0009/0014). One merged
// document (gen:openapi-public) → a single unified sidebar grouped by resource
// tag, not a per-service switcher: the flat /api namespace (ADR-0017) hides
// service topology. Served same-origin under the /devportal session gate; the
// built-in "try it" hits the real edge.
export function ApiReference() {
  return (
    <ApiReferenceReact
      configuration={{
        url: "/devportal/openapi/internal.json",
        // No CDN: self-host fonts so the bundle stays offline-clean and CSP-safe
        // (font-src 'self', ADR-0014). Scalar's own theme is a deliberate island.
        withDefaultFonts: false,
      }}
    />
  );
}
