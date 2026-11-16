# media-sso

Recipes to put Keycloak (OIDC) in front of a Docker-based media stack: Jellyfin, Seerr, qui and Beszel. Each script does a dry run or
a backup first and has a rollback. They are written for one concrete layout (SSH to the media host, compose files under `/opt/media`,
`/opt/qui`), so read each script and adjust paths before you run it. **They are examples, not a turnkey installer.**

Common settings (environment variables): `MEDIA_HOST` (host running the containers), `SSH_USER` (default `$USER`, needs sudo),
`SSH_KEY`, `SSO_ISSUER` (realm URL, e.g. `https://sso.example.com/realms/master`), `JELLYFIN_URL`, `QUI_URL`, `TZ_NAME`.
Client secrets are asked for with hidden input and written to mode-600 files; they are never printed.

| Piece | Script | Backup | Rollback |
|---|---|---|---|
| Jellyfin: only members of Keycloak groups `media-users` / `media-admins` may sign in with SSO, admins become admins | `jellyfin-sso-gating.sh` | `/opt/backups/media-sso-<ts>/` | `--rollback <ts>` |
| Jellyfin: "Sign in with SSO" button on the login page | `jellyfin-sso-button.sh` | branding.xml copy | `--rollback <ts>` |
| Seerr with OIDC (preview build, pinned by digest), tested on a copy first | `seerr-oidc.sh test / switch / configure` | `/opt/backups/seerr-switch-<ts>/` | `rollback <ts>` |
| qui (qBittorrent web UI) with Keycloak | `qui-oidc.sh enable` | compose file copy | `disable` |
| Beszel hub: Keycloak provider through its API | `beszel_oidc.py` | `/root/backups/beszel-users-oauth2-<ts>.json` | `--restore FILE` |

Order: create the Keycloak groups and clients and check a test user's token (the `groups` claim); try Jellyfin gating with that user;
Seerr on the test instance (port 5056); then qui and Beszel.

**Seerr and Moonfin:** Moonfin signs in with a Jellyfin or a local Seerr account, not SSO; SSO-only users set a password in their Seerr profile.

Tests (offline): `python3 -I -m unittest discover -s tests`.

License: Apache-2.0, see `LICENSE`.
