#!/bin/bash
# Seerr with OpenID Connect (Keycloak): the stable v3.5.1 has none, the preview build `preview-new-oidc` does (experimental).
# Run from an admin machine with SSH and sudo access to the media host (set MEDIA_HOST; optional SSH_USER, SSH_KEY):
#   bash ./seerr-oidc.sh status                  # shows live and test instance
#   bash ./seerr-oidc.sh test                    # (re)creates the TEST instance on http://<media-host>:5056 from a COPY of the live config
#   bash ./seerr-oidc.sh remove-test             # removes the test instance and its copy
#   bash ./seerr-oidc.sh switch                  # live: backup, pin the preview image by digest, restart seerr (about 30 s). Only after the test worked
#   bash ./seerr-oidc.sh configure test|live     # asks (hidden) for the Keycloak `seerr` client secret, backs up settings.json, writes the Keycloak provider and turns OIDC login on, restarts that instance
#   bash ./seerr-oidc.sh rollback <TIMESTAMP>    # live: restore compose file, settings and database from that backup, back to v3.5.1
# Keycloak client `seerr` (confidential; redirect URIs <SEERR_URL>/login/oidc/callback/keycloak and, for the test, http://<media-host>:5056/login/oidc/callback/keycloak;
# scopes openid email profile). In Seerr: Settings, Users, enable OpenID Connect sign-in, add provider (issuer = SSO_ISSUER, client id/secret).
# Users keep working with Jellyfin or local sign-in; Moonfin signs in with a Jellyfin or a LOCAL Seerr account (set a password in the Seerr profile). New users keep the REQUEST permission.
set -euo pipefail
H="${MEDIA_HOST:?set MEDIA_HOST to the host that runs the media containers}"
ISSUER="${SSO_ISSUER:-}"; TZ_NAME="${TZ_NAME:-UTC}"   # SSO_ISSUER e.g. https://sso.example.com/realms/master (needed for `configure`)
R() { ssh -i "${SSH_KEY:-$HOME/.ssh/id_ed25519}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 "${SSH_USER:-$USER}@$H" "$@"; }
IMG=ghcr.io/seerr-team/seerr:preview-new-oidc
case "${1:-status}" in
  status) R 'sudo docker ps --filter name=seerr --format "{{.Names}} {{.Image}} {{.Status}}"; for p in 5055 5056; do printf "port $p: "; curl -s -m 5 http://localhost:$p/api/v1/status | cut -c1-90; echo; done' ;;
  test)
    R "set -e; T=/opt/seerr-test; sudo install -d -m 755 \$T; sudo docker rm -f seerr-test >/dev/null 2>&1 || true; sudo rm -rf \$T/config; sudo cp -a /opt/media/config/seerr \$T/config
       sudo docker pull -q $IMG >/dev/null; sudo docker run -d --name seerr-test --user node:node --network media -p 5056:5055 -e TZ=$TZ_NAME -v \$T/config:/app/config --restart no $IMG >/dev/null; sleep 25
       curl -s -m 8 http://localhost:5056/api/v1/settings/public | python3 -c \"import sys,json; d=json.load(sys.stdin); print('test instance up, OIDC capable:', 'openIdProviders' in d)\"" ;;
  remove-test) R 'sudo docker rm -f seerr-test >/dev/null 2>&1; sudo rm -rf /opt/seerr-test; echo "test instance removed"' ;;
  switch)
    TS=$(date +%Y%m%d-%H%M%S)
    R "set -e; B=/opt/backups/seerr-switch-$TS; sudo install -d -m 700 \$B; sudo cp -a /opt/media/docker-compose.yml \$B/; sudo cp -a /opt/media/config/seerr/settings.json \$B/
       sudo python3 - <<PY
import sqlite3
s=sqlite3.connect('file:/opt/media/config/seerr/db/db.sqlite3?mode=ro', uri=True); d=sqlite3.connect('\$B/db.sqlite3'); s.backup(d); d.close()
PY
       sudo docker pull -q $IMG >/dev/null; DIG=\$(sudo docker inspect --format '{{index .RepoDigests 0}}' $IMG); echo \"pinning \$DIG\"
       sudo sed -i -E \"/container_name: seerr\\\$/,/ports:/ s#image: ghcr.io/seerr-team/seerr:.*#image: \$DIG#\" /opt/media/docker-compose.yml
       sudo grep -n -B2 'seerr-team/seerr' /opt/media/docker-compose.yml | head -6
       cd /opt/media && sudo docker compose up -d seerr 2>&1 | tail -2; sleep 30
       curl -s -m 8 http://localhost:5055/api/v1/status | cut -c1-120; echo; echo 'backup: '\$B"
    echo "rollback with: bash $0 rollback $TS" ;;
  configure)
    [ -n "$ISSUER" ] || { echo "set SSO_ISSUER"; exit 1; }
    W="${2:?test|live}"
    case "$W" in test) DIR=/opt/seerr-test/config; CT=seerr-test; PORT=5056;; live) DIR=/opt/media/config/seerr; CT=seerr; PORT=5055;; *) echo "test or live"; exit 1;; esac
    read -rsp "Keycloak client secret of 'seerr' (hidden): " SEC; echo; [ -n "$SEC" ] || { echo "empty"; exit 1; }
    TS=$(date +%Y%m%d-%H%M%S)
    printf '%s' "$SEC" | R "set -e; sudo install -d -m 700 /opt/backups/seerr-oidc-$TS; sudo cp -a $DIR/settings.json /opt/backups/seerr-oidc-$TS/settings.json
      sudo python3 -c \"
import json,sys
p='$DIR/settings.json'; d=json.load(open(p)); sec=sys.stdin.read().strip()
d.setdefault('main',{})['oidcLogin']=True
d['oidc']={'providers':[{'slug':'keycloak','name':'Keycloak','issuerUrl':'$ISSUER','clientId':'seerr','clientSecret':sec,'scopes':'openid email profile groups','requiredClaims':'','newUserLogin':True}]}
json.dump(d,open(p,'w'),indent=1)
\"
      sudo docker restart $CT >/dev/null; sleep 25
      curl -s -m 8 http://localhost:$PORT/api/v1/settings/public | python3 -c \"import sys,json; d=json.load(sys.stdin); print('openIdProviders:', d.get('openIdProviders'), ' oidcLogin:', d.get('oidcLogin'))\"
      echo 'backup: /opt/backups/seerr-oidc-$TS (restore settings.json there and restart $CT)'"
    unset SEC ;;
  rollback)
    TS="${2:?timestamp}"
    R "set -e; B=/opt/backups/seerr-switch-$TS; sudo test -s \$B/docker-compose.yml; cd /opt/media; sudo docker compose stop seerr >/dev/null
       sudo cp -a \$B/docker-compose.yml /opt/media/docker-compose.yml; sudo cp -a \$B/settings.json /opt/media/config/seerr/settings.json
       sudo cp -a \$B/db.sqlite3 /opt/media/config/seerr/db/db.sqlite3; sudo rm -f /opt/media/config/seerr/db/db.sqlite3-wal /opt/media/config/seerr/db/db.sqlite3-shm
       sudo chown 1000:1000 /opt/media/config/seerr/db/db.sqlite3 2>/dev/null || true
       sudo docker compose up -d seerr 2>&1 | tail -1; sleep 25; curl -s -m 8 http://localhost:5055/api/v1/status | cut -c1-100" ;;
  *) echo "usage: $0 status|test|remove-test|switch|configure test|live|rollback <TS>"; exit 1 ;;
esac
