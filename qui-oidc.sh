#!/bin/bash
# qui (qBittorrent web UI, container `qui` in /opt/qui on the media host): add Keycloak sign-in.
#   bash ./qui-oidc.sh enable      # asks for the Keycloak client secret (hidden), writes it to /opt/qui/oidc.secret (mode 600), adds the OIDC variables, restarts qui
#   bash ./qui-oidc.sh disable     # restores the compose file from before enable
# Needs SSO_ISSUER (e.g. https://sso.example.com/realms/master), QUI_URL (e.g. https://qui.example.com), optional TZ_NAME (must match the TZ line in your compose file, default UTC).
# Keycloak client `qui` (confidential; redirect URI <QUI_URL>/api/auth/oidc/callback; scopes openid email profile). The built-in login stays on (break-glass).
set -euo pipefail
H="${MEDIA_HOST:?set MEDIA_HOST to the host that runs the media containers}"
ISSUER="${SSO_ISSUER:-}"; QUI_URL="${QUI_URL:-}"; TZ_NAME="${TZ_NAME:-UTC}"
R() { ssh -i "${SSH_KEY:-$HOME/.ssh/id_ed25519}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 "${SSH_USER:-$USER}@$H" "$@"; }
case "${1:-}" in
  enable)
    [ -n "$ISSUER" ] && [ -n "$QUI_URL" ] || { echo "set SSO_ISSUER and QUI_URL"; exit 1; }
    read -r -s -p "Keycloak client secret of 'qui' (hidden): " S; echo; [ -n "$S" ] || { echo "empty"; exit 1; }
    printf '%s' "$S" | R "sudo install -m 600 -o 1000 -g 1000 /dev/stdin /opt/qui/oidc.secret"; unset S
    R "set -e; cd /opt/qui; sudo cp -a docker-compose.yml docker-compose.yml.before-oidc
       sudo python3 - <<'PY'
p='/opt/qui/docker-compose.yml'; s=open(p).read()
env='''      - QUI__OIDC_ENABLED=true
      - QUI__OIDC_ISSUER=$ISSUER
      - QUI__OIDC_CLIENT_ID=qui
      - QUI__OIDC_CLIENT_SECRET_FILE=/run/secrets/oidc
      - QUI__OIDC_REDIRECT_URL=$QUI_URL/api/auth/oidc/callback
      - QUI__OIDC_DISABLE_BUILT_IN_LOGIN=false
'''
if 'QUI__OIDC_ENABLED' not in s:
    s=s.replace('      - TZ=$TZ_NAME\n','      - TZ=$TZ_NAME\n'+env,1)
    s=s.replace('      - /opt/qui/config:/config\n','      - /opt/qui/config:/config\n      - /opt/qui/oidc.secret:/run/secrets/oidc:ro\n',1)
open(p,'w').write(s)
PY
       sudo docker compose up -d 2>&1 | tail -1; sleep 12; sudo docker ps --filter name=qui --format '{{.Status}}'; sudo docker logs --tail 4 qui 2>&1 | grep -i -E 'oidc|error' | cut -c1-160 | head -3" ;;
  disable) R "set -e; cd /opt/qui; sudo cp -a docker-compose.yml.before-oidc docker-compose.yml; sudo docker compose up -d 2>&1 | tail -1; echo restored" ;;
  *) echo "usage: $0 enable|disable"; exit 1 ;;
esac
