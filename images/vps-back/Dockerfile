# syntax=docker/dockerfile:1

# vps-back: the API (Rust, axum). It serves the files of STATIC_DIR under
# /static/, and with GITHUB_TOKEN it writes github-stats.json there.
#
# Build context: a checkout of https://github.com/TomPlanche/vps-back.

FROM rust:1-slim-trixie AS build
WORKDIR /src
COPY . .
# The cache mounts keep the crates and the compiled dependencies between builds.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked \
 && mkdir /out \
 && cp target/release/vps-back /out/

FROM debian:trixie-slim
# curl is for the health check only: TLS comes from rustls, so no OpenSSL.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 1000 --create-home app
COPY --from=build /out/vps-back /usr/local/bin/
USER app
WORKDIR /home/app
ENV HOST=0.0.0.0 \
    PORT=8000 \
    STATIC_DIR=/data/static \
    RUST_LOG=info
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/" || exit 1
CMD ["vps-back"]
