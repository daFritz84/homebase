# Caddy with the official Cloudflare DNS plugin (required for the DNS-01 ACME challenge).
# The builder image is xcaddy-based: build the plugin-enabled binary, then drop it
# into the official runtime image (alpine base, non-root user, entrypoint preserved).
# Single version pin: bump CB_VERSION here and the image tag in compose.yaml.
# NB: the builder image ships ENV CADDY_VERSION=vX.Y.Z — the ARG is deliberately NOT
# named CADDY_VERSION so the image env cannot leak into the xcaddy build.
ARG CB_VERSION=2.11.7
FROM caddy:${CB_VERSION}-builder AS builder
ARG CB_VERSION
RUN xcaddy build v${CB_VERSION} --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:${CB_VERSION}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
