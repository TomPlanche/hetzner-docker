# syntax=docker/dockerfile:1

# sifa-page: a static page built from a sifa.id profile, served by Caddy at
# tomplanche.com/sifa-page/.
#
# Build context: a checkout of https://github.com/singi-labs/sifa-page.
# No server runs: `docker compose run --rm sifa-page` fetches the profile of
# SIFA_ID, builds the page and replaces the content of the directory mounted
# on /out (the web root that Caddy serves).

FROM node:24-alpine
WORKDIR /src
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
COPY --chmod=755 <<'EOF' /usr/local/bin/publish
#!/bin/sh
set -eu
: "${SIFA_ID:?set SIFA_ID to the DID or handle of the profile}"
# The image has no /out: it exists only when a directory is mounted on it.
if [ ! -d /out ]; then
    echo "error: mount the web root of the page on /out" >&2
    exit 1
fi
node build.mjs
find /out -mindepth 1 -delete
cp -R dist/. /out/
echo "published $(find /out -type f | wc -l) files to the web root"
EOF
CMD ["publish"]
