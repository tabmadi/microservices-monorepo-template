# Untitled UI upstream tracking

This tree holds Untitled UI React ports as committed source (ADR-0014) — not
runtime-fetched. Untitled UI ships source you own, built on
[React Aria Components](https://react-spectrum.adobe.com/react-aria/); the files
below are vendored verbatim from upstream and mirror its layout:

| Path                         | Upstream                          |
|------------------------------|-----------------------------------|
| `components/base/*`          | `components/base/*`               |
| `components/application/*`   | `components/application/*`        |
| `components/foundations/*`   | `components/foundations/*`        |
| `src/styles/theme.css`       | `styles/theme.css` (design tokens)|
| `src/styles/typography.css`  | `styles/typography.css`           |
| `src/styles/globals.css`     | `styles/globals.css`              |
| `src/utils/cx.ts`            | `utils/cx.ts`                     |
| `src/utils/is-react-component.ts` | `utils/is-react-component.ts` |

## Vendored components

Only components actually used by the app are vendored, plus their transitive
closure (the CLI's `--include-all-components` pulls the whole base library, so
after adding a component we prune everything outside the used closure — see the
minimalism rule in ADR-0014). Current inventory:

| Component        | Path                                        | Used by                       |
|------------------|---------------------------------------------|-------------------------------|
| Button           | `base/buttons/button.tsx`                   | error, checkout, kitchen-sink |
| Input            | `base/input/{input,label,hint-text}.tsx`    | checkout, KratosFlow          |
| Badge            | `base/badges/*`                             | checkout, kitchen-sink        |
| LoadingIndicator | `application/loading-indicator/*`           | loading, kitchen-sink         |
| Table            | `application/table/table.tsx`               | products, kitchen-sink        |

`Input` pulls `base/tooltip`; `Table` pulls `base/{checkbox,dropdown,avatar,radio-buttons,toggle}`
and `foundations/dot-icon` as its closure. React Aria's `Button` strips
`name`/`value`/`formNoValidate`, so Kratos's node-graph submit buttons stay native
`<button>` (see `auth/KratosFlow.tsx`).

`Table` must be rendered from a Client Component: React Aria builds its collection
by introspecting `Row`/`Cell` children, which fails if they're created in a Server
Component (they arrive as opaque client references). RSC pages fetch the data and
pass it to a `"use client"` child that renders the table (see `panel/products/_components/products-table.tsx`).

| Tracked                            | Version | Synced on  |
|------------------------------------|---------|------------|
| Untitled UI React (source)         | main    | 2026-07-05 |
| react-aria-components              | 1.19.0  | 2026-05-20 |
| @untitledui/icons                  | 0.0.22  | 2026-05-20 |
| tailwindcss-react-aria-components  | 2.2.0   | 2026-05-20 |
| tailwindcss-animate                | 1.0.7   | 2026-05-20 |

Annual bump cadence. To re-sync:

1. Add/update components with the Untitled UI CLI, non-interactively:
   `npx untitledui@latest add <component> -y` (the `-y` flag is its AI-agent/CI
   mode). Keep the `base|application|foundations` layout. Then prune any files
   outside the used closure the CLI dragged in. The npm dep-install step the CLI
   runs at the end fails in this Bun project — that's expected; deps are managed
   in `package.json`.
2. Diff `src/styles/theme.css`, `typography.css`, `globals.css`, and `src/utils/`
   against upstream.
3. Open a PR titled `feat(frontend): bump Untitled UI to <version>`.
4. Update the tables above and the dates.
