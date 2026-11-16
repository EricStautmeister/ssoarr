#!/bin/bash
# Add the "Sign in with SSO" button to the Jellyfin login page. The SSO plugin has no button of its own: it works through Jellyfin's login disclaimer (branding) and custom CSS.
#   bash ./jellyfin-sso-button.sh                      # dry run: shows the current branding
#   bash ./jellyfin-sso-button.sh --apply              # backup, write the button, restart Jellyfin (about 20 s), verify through the public branding API
#   bash ./jellyfin-sso-button.sh --rollback <TS>      # restore the saved branding.xml and restart
# The button is a link (not a form: a GET form would drop the ?isLinking=false the plugin needs). Provider name: keycloak. Local password login stays as it is.
set -euo pipefail
H="${MEDIA_HOST:?set MEDIA_HOST to the host that runs the media containers}"
R() { ssh -i "${SSH_KEY:-$HOME/.ssh/id_ed25519}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 "${SSH_USER:-$USER}@$H" "$@"; }
B=/opt/media/config/jellyfin/branding.xml
URL="${JELLYFIN_URL:?set JELLYFIN_URL, e.g. https://jellyfin.example.com}/sso/OID/start/keycloak?isLinking=false"
MODE=dry; TS=""
while [ $# -gt 0 ]; do case "$1" in --apply) MODE=apply;; --rollback) MODE=rollback; TS="${2:?timestamp}"; shift;; *) echo "unknown option $1"; exit 1;; esac; shift; done
echo "current branding: $(curl -s -m 8 http://$H:8096/Branding/Configuration | cut -c1-200)"
[ "$MODE" = dry ] && { echo "dry run: nothing changed"; exit 0; }
if [ "$MODE" = rollback ]; then
  R "sudo cp -a /opt/backups/media-sso-$TS/branding.xml $B && sudo docker restart jellyfin >/dev/null && echo restored"
else
  TS=$(date +%Y%m%d-%H%M%S)
  R "sudo install -d -m 700 /opt/backups/media-sso-$TS && sudo cp -a $B /opt/backups/media-sso-$TS/branding.xml && echo 'backup: /opt/backups/media-sso-$TS'"
  R "sudo python3 - <<PY
import html
p='$B'; s=open(p).read()
disc='<a class=\"raised block emby-button button-submit\" href=\"$URL\">Sign in with SSO</a>'
css='a.raised.emby-button { padding: 0.9em 1em; color: inherit !important; } .disclaimerContainer { display: block; }'
s=s.replace('<LoginDisclaimer />','<LoginDisclaimer>'+html.escape(disc,quote=False)+'</LoginDisclaimer>').replace('<CustomCss />','<CustomCss>'+html.escape(css,quote=False)+'</CustomCss>')
open(p,'w').write(s)
PY
sudo docker restart jellyfin >/dev/null"
fi
for i in $(seq 1 30); do c=$(curl -s -o /dev/null -w '%{http_code}' -m 4 http://$H:8096/System/Info/Public || true); [ "$c" = 200 ] && break; sleep 2; done
echo "Jellyfin: HTTP $c"; echo "branding now: $(curl -s -m 8 http://$H:8096/Branding/Configuration | cut -c1-330)"
echo "If the button misbehaves: bash $0 --rollback $TS"
