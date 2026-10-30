# syntax=docker/dockerfile:1

# atkuzu: a Takuzu game (SvelteKit, adapter-node, SQLite, atproto OAuth) with a
# daily puzzle.
#
# Build context: a checkout of https://tangled.org/tomplanche.com/atkuzu.
# 2 targets:
# - app: the web server. The SQLite database is DATABASE_URL, in /data. With
#   DAILY_DIR, the app serves the daily puzzles from that directory.
# - daily: a job that writes the missing daily puzzles (static JSON files) into
#   the directory mounted on /app/static/daily. Mount the same directory as the
#   DAILY_DIR of the app: a new daily then needs no rebuild and no restart.

# The Rust crate takuzu-grid-factory gives the WebAssembly module of /play and
# the native generator of the dailies.
FROM rust:1-slim-trixie AS rust
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    rustup target add wasm32-unknown-unknown \
 && cargo install --locked wasm-pack
WORKDIR /src
COPY takuzu-grid-factory ./takuzu-grid-factory
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/takuzu-grid-factory/target \
    cd takuzu-grid-factory \
 && wasm-pack build --target web --out-dir /out/pkg \
 && cargo build --release --locked \
 && cp target/release/takuzu-grid-factory /out/

FROM node:24-slim AS deps
ENV CI=true
# better-sqlite3 compiles its native module when no prebuilt one fits.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g pnpm@11.25.0
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

FROM deps AS build
COPY . .
COPY --from=rust /out/pkg ./src/lib/wasm/pkg
# The server code opens the database at import time, and the build imports it.
RUN DATABASE_URL=placeholder pnpm build

# adapter-node does not bundle `dependencies`: the server imports them at runtime.
FROM deps AS prod-deps
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile --prod

FROM node:24-slim AS app
WORKDIR /app
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000 \
    DATABASE_URL=/data/atkuzu.db \
    MIGRATIONS_FOLDER=/app/drizzle
# package.json gives "type": "module" to build/index.js. The server applies the
# migrations of drizzle/ at start-up.
COPY package.json ./
COPY drizzle ./drizzle
COPY --from=prod-deps /app/node_modules ./node_modules
COPY --from=build /app/build ./build
RUN mkdir /data && chown node:node /data
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:' + process.env.PORT + '/_app/version.json').then((r) => process.exit(r.ok ? 0 : 1), () => process.exit(1))"
CMD ["node", "build/index.js"]

# The daily job: scripts/generate-daily.ts with tsx (a dev dependency), and the
# native generator at the path where the script looks for it.
FROM deps AS daily
COPY . .
COPY --from=rust /out/takuzu-grid-factory ./takuzu-grid-factory/target/release/takuzu-grid-factory
COPY --chmod=755 <<'EOF' /usr/local/bin/atkuzu-daily
#!/bin/bash
# Writes the missing dailies: each day after the last published one, up to
# today in Paris time. A published daily never changes, so a day that has its
# file is left alone, and the job can run as often as you want.
set -euo pipefail
: "${ATKUZU_DAILY_SEED:?set ATKUZU_DAILY_SEED, the master seed of the daily archive}"
dir=/app/static/daily
# The image has no static/daily: it exists only when a directory is mounted on it.
if [ ! -d "$dir" ]; then
    echo "error: mount the daily directory on $dir" >&2
    exit 1
fi
today=$(TZ=Europe/Paris date +%F)
last=$(find "$dir" -maxdepth 1 -name '????-??-??.json' -printf '%f\n' | sort | tail -n 1)
if [ -n "$last" ]; then
    day=$(date -u -d "${last%.json} + 1 day" +%F)
else
    day=$today
fi
# One timestamp per day, at noon UTC, as the script expects.
timestamps=()
while [[ ! "$day" > "$today" ]]; do
    timestamps+=("$(date -u -d "${day}T12:00:00" +%s)")
    day=$(date -u -d "$day + 1 day" +%F)
done
if [ "${#timestamps[@]}" -eq 0 ]; then
    echo "up to date: the daily of $today exists"
    exit 0
fi
exec node_modules/.bin/tsx scripts/generate-daily.ts "${timestamps[@]}"
EOF
CMD ["atkuzu-daily"]
