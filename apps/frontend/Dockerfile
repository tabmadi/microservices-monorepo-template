# syntax=docker/dockerfile:1.7
# Bun is the only JS runtime in this image — install, build, and the
# production server.js all run under Bun. Next's standalone output is
# officially Node-targeted, but Bun runs it in practice and removing Node
# keeps the platform on a single runtime (ADR-0000 §"one way to do things").
ARG BUN_VERSION=1.3.14

FROM oven/bun:${BUN_VERSION}-alpine AS deps
WORKDIR /app
COPY package.json bun.lock ./
COPY apps/frontend/package.json apps/frontend/
RUN --mount=type=cache,target=/root/.bun bun install --frozen-lockfile

FROM oven/bun:${BUN_VERSION}-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules /app/node_modules
COPY . .
# Build identity baked into the bundle (ADR-0013): next.config inlines
# NEXT_PUBLIC_SERVICE_VERSION from SERVICE_VERSION at build, so the shipped JS and
# the X-App-Version response header both report the git SHA / release.
ARG SERVICE_VERSION=dev
ENV SERVICE_VERSION=$SERVICE_VERSION
# Optional, and deliberately EMPTY by default. `output: "standalone"` freezes
# next.config into server.js, so passing EDGE_ORIGIN here bakes the server-action
# CSRF allowlist — and with it one env's host — into the image, which forfeits the
# build-once / promote-by-digest flow (ADR-0013). Unset, the allowlist is empty and
# the check falls back to Origin == (X-Forwarded-)Host, which ADR-0017's same-origin
# layout already satisfies. Pass it only for a build you intend to pin to one env.
# The RUNTIME EDGE_ORIGIN that server components fetch with is separate and comes
# from the pod env (infra/gitops/services/<env>/values/frontend.yaml).
ARG EDGE_ORIGIN=
ENV EDGE_ORIGIN=$EDGE_ORIGIN
RUN cd apps/frontend && bun run build

FROM oven/bun:${BUN_VERSION}-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/apps/frontend/.next/standalone ./
COPY --from=build /app/apps/frontend/.next/static    ./apps/frontend/.next/static
COPY --from=build /app/apps/frontend/public          ./apps/frontend/public
EXPOSE 3000
CMD ["bun", "apps/frontend/server.js"]
