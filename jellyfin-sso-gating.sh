#!/bin/bash
# Jellyfin SSO plugin: only members of the media groups may sign in with Keycloak, admins become Jellyfin admins, every media user sees all libraries.
# Run from an admin machine with SSH and sudo access to the media host (set MEDIA_HOST; optional SSH_USER, SSH_KEY):
#   bash ./jellyfin-sso-gating.sh                           # dry run: shows the current and the new plugin settings, changes nothing
#   bash ./jellyfin-sso-gating.sh --apply --keycloak-ready  # backup, edit, restart Jellyfin (about 20 s), health check
#   bash ./jellyfin-sso-gating.sh --rollback <TIMESTAMP>    # restore the saved plugin files and restart
# --keycloak-ready is your confirmation that (1) the groups media-users and media-admins exist, (2) the client `jellyfin` has the client scope `groups`
# (Client scopes tab, default) so the token carries the groups claim, (3) your test user is in media-users. Without (2) every SSO sign-in fails until a rollback;
# local Jellyfin accounts always keep working. Test with one user first, then everyone.
# Changed in SSO-Auth.xml: EnableAuthorization=true, Roles and AdminRoles with BOTH spellings of every group (Keycloak sends the full path /media-users in the groups claim,
# checked on a test user's ID token), RoleClaim=groups, OidScopes+=[groups]; EnableAllFolders stays true.
set -euo pipefail
H="${MEDIA_HOST:?set MEDIA_HOST to the host that runs the media containers}"
R() { ssh -i "${SSH_KEY:-$HOME/.ssh/id_ed25519}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 "${SSH_USER:-$USER}@$H" "$@"; }
CFG=/opt/media/config/jellyfin/data/plugins/configurations
MODE=dry; TS=""
while [ $# -gt 0 ]; do case "$1" in --apply) MODE=apply;; --keycloak-ready) READY=1;; --rollback) MODE=rollback; TS="${2:?timestamp}"; shift;; *) echo "unknown option $1"; exit 1;; esac; shift; done
show() { R "sudo python3 - <<'PY'
import re
s=open('$CFG/SSO-Auth.xml').read()
def g(t):
    m=re.search(r'<%s\s*/>'%t,s)
    if m: return '(empty)'
    m=re.search(r'<%s>(.*?)</%s>'%(t,t),s,re.S)
    return re.sub(r'\s+',' ',re.sub(r'<[^>]+>',' ',m.group(1))).strip() if m else '(absent)'
for t in ('Enabled','EnableAuthorization','EnableAllFolders','Roles','AdminRoles','OidScopes','RoleClaim'): print('  %-22s %s'%(t,g(t)))
PY"; }
echo "current plugin settings:"; show
if [ "$MODE" = dry ]; then echo "dry run: nothing changed. New: EnableAuthorization=true, Roles=/media-users /media-admins /admins (and without slash), AdminRoles=/media-admins /admins (and without slash), RoleClaim=groups, OidScopes=groups"; exit 0; fi
if [ "$MODE" = rollback ]; then
  R "sudo test -s /opt/backups/media-sso-$TS/SSO-Auth.xml && sudo cp -a /opt/backups/media-sso-$TS/SSO-Auth.xml $CFG/SSO-Auth.xml && sudo docker restart jellyfin >/dev/null && echo restored"
else
  [ "${READY:-0}" = 1 ] || { echo "refusing: add --keycloak-ready after the Keycloak steps (see the header of this script)"; exit 2; }
  TS=$(date +%Y%m%d-%H%M%S)
  R "sudo install -d -m 700 /opt/backups/media-sso-$TS && sudo cp -a $CFG/SSO-Auth.xml $CFG/Moonfin.Server.xml /opt/backups/media-sso-$TS/ && echo 'backup: /opt/backups/media-sso-$TS'"
  R "sudo python3 - <<'PY'
import re
p='$CFG/SSO-Auth.xml'; s=open(p).read()
def items(vals): return '<string>'+'</string><string>'.join(vals)+'</string>'
def ensure(tag, vals):
    global s
    if re.search(r'<%s\s*/>'%tag, s): s=re.sub(r'<%s\s*/>'%tag, '<%s>%s</%s>'%(tag,items(vals),tag), s, count=1); return
    m=re.search(r'<%s>(.*?)</%s>'%(tag,tag), s, re.S)
    have=re.findall(r'<string>(.*?)</string>', m.group(1)) if m else []
    add=[v for v in vals if v not in have]
    if m and add: s=s.replace(m.group(0), '<%s>%s</%s>'%(tag, m.group(1)+items(add), tag), 1)
s=s.replace('<EnableAuthorization>false</EnableAuthorization>','<EnableAuthorization>true</EnableAuthorization>')
ensure('Roles',['/media-users','/media-admins','/admins','media-users','media-admins','admins']); ensure('AdminRoles',['/media-admins','/admins','media-admins','admins']); ensure('OidScopes',['groups'])
if '<RoleClaim>' not in s: s=s.replace('</AdminRoles>','</AdminRoles>\n          <RoleClaim>groups</RoleClaim>',1)
open(p,'w').write(s)
PY"
  R "sudo docker restart jellyfin >/dev/null"
fi
for i in $(seq 1 30); do curl -s -o /dev/null -m 4 "http://$H:8096/System/Info/Public" && break; sleep 2; done
echo "Jellyfin answers: $(curl -s -o /dev/null -w '%{http_code}' -m 5 http://$H:8096/System/Info/Public)"
echo "new plugin settings:"; show
echo "Now test: sign in with Keycloak as a test user at ${JELLYFIN_URL:-your Jellyfin URL}. If it fails: bash $0 --rollback $TS"
