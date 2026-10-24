# Caddy with the official Cloudflare DNS plugin (required for the DNS-01 ACME challenge).
# The 2.11 builder image is xcaddy-based: build the plugin-enabled binary, then drop it
# into the official runtime image (alpine base, non-root user, entrypoint preserved).
FROM caddy:2.11.7-builder AS builder
RUN xcaddy build v2.11.7 --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:2.11.7
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
