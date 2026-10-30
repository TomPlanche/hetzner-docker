# syntax=docker/dockerfile:1

# The portfolio front (SvelteKit, adapter-node): `site` is the main branch,
# `next-site` the next branch.
#
# Build context: a checkout of https://github.com/TomPlanche/portfolio-v222.
# Build arguments COMMIT_SHA, COMMIT_DATE and COMMIT_URL describe the checkout
# (`just build` sets them from git).

FROM node:24-alpine AS base
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    CI=true
# pnpm comes from corepack, at the version of `packageManager` in package.json.
RUN corepack enable
WORKDIR /app

FROM base AS deps
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

FROM deps AS build
COPY . .
ARG COMMIT_SHA=""
ARG COMMIT_DATE=""
ARG COMMIT_URL=""
# The layout and the sitemap import static/website_infos.json (the last commit),
# which git ignores. Write it in the shape of the GitHub API answer, or as an
# empty list: the site then shows no commit.
RUN node -e ' \
      const { COMMIT_SHA: sha, COMMIT_DATE: date, COMMIT_URL: html_url } = process.env; \
      const infos = sha && date && html_url ? [{ sha, html_url, commit: { committer: { date } } }] : []; \
      require("fs").writeFileSync("static/website_infos.json", JSON.stringify(infos) + "\n");' \
 && pnpm build

# adapter-node does not bundle `dependencies`: the server imports them at runtime.
FROM base AS prod-deps
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile --prod

FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000
# package.json gives "type": "module" to build/index.js.
COPY package.json ./
COPY --from=prod-deps /app/node_modules ./node_modules
COPY --from=build /app/build ./build
USER node
EXPOSE 3000
# A static file, not an SSR route: SSR calls the GitHub API (60 requests per hour).
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null "http://127.0.0.1:${PORT}/_app/version.json" || exit 1
CMD ["node", "build/index.js"]
