# syntax=docker/dockerfile:1.7
# Built from this directory as context (apps/admin), independent of the repo-root
# .dockerignore the Go service images rely on (it excludes apps/).
#
# Lowdefy 5 requires Node + pnpm, so this image — unlike the Go/bun runtime images
# — is Node-based. One of the two Node exceptions ADR-0001 sanctions, and the only
# one that ships as an image. No repo runtime code is Node: Lowdefy is a
# third-party app we install and run, so the runtime is upstream's choice, not
# ours. Concretely, bun cannot displace it: the CLI aborts unless pnpm is on PATH
# (its startUp checks), and `lowdefy start` spawns `pnpm run start` → `next start`,
# whose bin is `#!/usr/bin/env node`. Running it under bun would mean aliasing node
# and still installing pnpm — an unsupported hack (nobody upstream has attempted
# it) for no gain, since the runtime is sealed in this image either way.
ARG NODE_VERSION=22
ARG LOWDEFY_VERSION=5.4.0
FROM node:${NODE_VERSION}-alpine AS lowdefy-cli
ARG LOWDEFY_VERSION

ENV NODE_ENV=production \
  PNPM_CONFIG_DANGEROUSLY_ALLOW_ALL_BUILDS=true \
  PNPM_CONFIG_FETCH_TIMEOUT=600000 \
  PNPM_CONFIG_FETCH_RETRIES=5 \
  PNPM_CONFIG_FETCH_RETRY_MAXTIMEOUT=120000 \
  PNPM_CONFIG_NETWORK_CONCURRENCY=4
# corepack provides the pnpm that Lowdefy requires at build and start. pnpm 10+
# hard-fails (ERR_PNPM_IGNORED_BUILDS) when a dependency's build script is blocked;
# the Lowdefy server's deps (sharp, @sentry/cli) need theirs, so allow them.
RUN --mount=type=cache,target=/root/.npm \
  corepack enable \
  && npm install -g lowdefy@${LOWDEFY_VERSION} \
  && npm cache clean --force

FROM lowdefy-cli AS build
ARG LOWDEFY_VERSION

WORKDIR /app

COPY . .

# Lowdefy's own `@lowdefy/server` fetch (a raw axios GET to registry.npmjs.org,
# not npm's client) reliably gets "socket hang up"/400 through this project's
# egress proxy; npm's own fetcher (pacote) does not. Pre-populate the server
# directory via `npm pack` so `lowdefy build` finds it already present and
# skips its own fetch (see lowdefy's getServer.js: skips fetch if
# .lowdefy/server/package.json name+version already match).
RUN --mount=type=cache,target=/root/.npm \
  mkdir -p .lowdefy/server \
  && npm pack "@lowdefy/server@${LOWDEFY_VERSION}" --pack-destination /tmp \
  && tar xzf "/tmp/lowdefy-server-${LOWDEFY_VERSION}.tgz" --strip-components=1 -C .lowdefy/server \
  && rm "/tmp/lowdefy-server-${LOWDEFY_VERSION}.tgz" \
  && lowdefy build

FROM lowdefy-cli AS runtime

# Build identity (ADR-0013): the commit SHA, recorded as the standard OCI revision
# label so the image reports exactly what was built (the same SERVICE_VERSION build
# arg the frontend takes, so one apps matrix builds both).
ARG SERVICE_VERSION=dev
LABEL org.opencontainers.image.revision="${SERVICE_VERSION}"

WORKDIR /app

COPY --from=build --chown=node:node /app/lowdefy.yaml ./lowdefy.yaml
COPY --from=build --chown=node:node /app/.lowdefy ./.lowdefy

EXPOSE 3000

USER node

# `lowdefy start` serves the built app on :3000; auth is enforced upstream at the
# edge (ADR-0012), this process trusts the forwarded X-User-Email header.
CMD ["lowdefy", "start"]
