# Caddy with the official Cloudflare DNS plugin (required for the DNS-01 ACME challenge).
# Built from the official builder image; only official Caddy + the official caddy-dns plugin are trusted.
FROM caddy:2.11.7-builder

RUN caddy addmodule github.com/caddy-dns/cloudflare@v0.2.4
