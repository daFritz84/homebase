# Configuration variables
Referenced by `services.yaml` via `{{HOMEPAGE_VAR_*}}`; defined in `.env`
(see `.env.example`).

- HOMEPAGE_ALLOWED_HOSTS (required since v1.0 — host-header check, not a secret)
- HOMEPAGE_VAR_ADGUARD_USER
- HOMEPAGE_VAR_ADGUARD_PASS

The auth-gate variables (`HOMEPAGE_AUTH_*`, `HOMEPAGE_OIDC_*`,
`HOMEPAGE_EXTERNAL_URL`) are plain environment variables consumed by the app
itself, not `{{HOMEPAGE_VAR_*}}` template vars — see `.env.example` and
[docs/services.md](../../docs/services.md) (Authelia SSO).
