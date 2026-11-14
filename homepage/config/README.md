# Configuration variables
Referenced by `services.yaml` via `{{HOMEPAGE_VAR_*}}`; defined in `.env`
(see `.env.example`).

- HOMEPAGE_ALLOWED_HOSTS (required since v1.0 — host-header check, not a secret)
- HOMEPAGE_VAR_ADGUARD_USER
- HOMEPAGE_VAR_ADGUARD_PASS
- HOMEPAGE_VAR_KUMA_SLUG (Uptime Kuma status-page slug — the `uptimekuma` widget
  reads a status page, not an API key; create one in Kuma and use its slug)
- HOMEPAGE_VAR_BESZEL_USER / HOMEPAGE_VAR_BESZEL_PASS (the Beszel hub SUPERUSER
  email+password — the hub requires a superuser for API access, not an API key;
  password = Bitwarden `beszel-superuser-password`)
- HOMEPAGE_VAR_BESZEL_SYSTEMID (the Beszel system id / nice name for the widget)

The auth-gate variables (`HOMEPAGE_AUTH_*`, `HOMEPAGE_OIDC_*`,
`HOMEPAGE_EXTERNAL_URL`) are plain environment variables consumed by the app
itself, not `{{HOMEPAGE_VAR_*}}` template vars — see `.env.example` and
[docs/services.md](../../docs/services.md) (Authelia SSO).
