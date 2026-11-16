#!/usr/bin/env python3
"""Switch on the Keycloak OpenID Connect provider in the Beszel hub through its API (PocketBase), without clicking through its admin UI.

  sudo python3 -I beszel_oidc.py                 # dry run: shows the current oauth2 setting and what would change
  sudo python3 -I beszel_oidc.py --apply         # asks for the Keycloak client secret (hidden), backs up, changes, verifies
  sudo python3 -I beszel_oidc.py --restore FILE  # puts the saved oauth2 setting back (provider switched off again)
Needs the hub superuser in /etc/beszel-oidc/hub.secret (line 1 e-mail, line 2 password, mode 600: why root; or --creds FILE). Keycloak side: client `beszel` (confidential,
redirect URI <your beszel URL>/api/oauth2-redirect, scopes openid email profile). The backup (mode 600) goes to /root/backups.
Beszel's users collection only lets a VERIFIED user sign in (authRule verified=true): accounts you create for SSO must be verified.
"""
import argparse, getpass, json, os, sys, time, urllib.error, urllib.request

BASE = os.environ.get("SSO_ISSUER", "https://sso.example.com/realms/master").rstrip("/") + "/protocol/openid-connect"   # SSO_ISSUER = realm URL
HUB = os.environ.get("BESZEL_HUB", "http://127.0.0.1:8090")   # BESZEL_HUB = hub base URL


def build_oauth2(current, client_id, client_secret):
    """The new oauth2 block of the users collection: the oidc provider added or replaced, everything else kept."""
    o = json.loads(json.dumps(current or {}))
    o["providers"] = [p for p in (o.get("providers") or []) if p.get("name") != "oidc"] + [{
        "name": "oidc", "displayName": "Keycloak", "clientId": client_id, "clientSecret": client_secret,
        "authURL": BASE + "/auth", "tokenURL": BASE + "/token", "userInfoURL": BASE + "/userinfo", "pkce": True}]
    o["enabled"] = True
    o.setdefault("mappedFields", {"id": "", "name": "name", "username": "", "avatarURL": "avatar"})
    return o


def redact(o):
    return json.loads(json.dumps(o or {}), object_hook=lambda d: {k: ("<redacted>" if "secret" in k.lower() else v) for k, v in d.items()})


def api(method, path, token=None, body=None, call=urllib.request.urlopen):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = token
    req = urllib.request.Request(HUB + path, method=method, headers=h, data=None if body is None else json.dumps(body).encode())
    try:
        with call(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"null")
        except ValueError:
            return e.code, None


def superuser_token(creds_file, call=urllib.request.urlopen):
    if os.path.exists(creds_file) and os.stat(creds_file).st_mode & 0o077:
        raise SystemExit("%s must be mode 600" % creds_file)
    with open(creds_file) as fh:
        lines = [l.rstrip("\n") for l in fh if l.strip()]
    st, js = api("POST", "/api/collections/_superusers/auth-with-password", None, {"identity": lines[0], "password": lines[1]}, call)
    if st != 200 or not (js or {}).get("token"):
        raise SystemExit("the hub refused the superuser login (HTTP %s)" % st)
    return js["token"]


def main(argv=None, call=urllib.request.urlopen, ask=getpass.getpass):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--restore", metavar="FILE")
    ap.add_argument("--client-id", default="beszel")
    ap.add_argument("--creds", default="/etc/beszel-oidc/hub.secret")
    ap.add_argument("--backup-dir", default="/root/backups")
    a = ap.parse_args(argv)
    tok = superuser_token(a.creds, call)
    st, col = api("GET", "/api/collections/users", tok, None, call)
    if st != 200:
        raise SystemExit("cannot read the users collection (HTTP %s)" % st)
    cur = col.get("oauth2") or {}
    print("current oauth2:", json.dumps(redact(cur)))
    if a.restore:
        with open(a.restore) as fh:
            old = json.load(fh)
        st, _ = api("PATCH", "/api/collections/users", tok, {"oauth2": old}, call)
        print("restored (HTTP %s)" % st)
        return 0 if st == 200 else 1
    if not a.apply:
        print("dry run: would add provider oidc (Keycloak, client %s) and enable OAuth2 on the users collection. Nothing changed." % a.client_id)
        return 0
    secret = ask("Keycloak client secret of '%s' (hidden): " % a.client_id).strip()
    if not secret:
        raise SystemExit("empty secret, nothing changed")
    os.makedirs(a.backup_dir, mode=0o700, exist_ok=True)
    bk = os.path.join(a.backup_dir, "beszel-users-oauth2-%s.json" % time.strftime("%Y%m%d-%H%M%S"))
    with open(os.open(bk, os.O_WRONLY | os.O_CREAT, 0o600), "w") as fh:
        json.dump(cur, fh)
    print("backup of the current setting:", bk)
    st, js = api("PATCH", "/api/collections/users", tok, {"oauth2": build_oauth2(cur, a.client_id, secret)}, call)
    if st != 200:
        print("hub refused the change (HTTP %s %s); restore with --restore %s" % (st, json.dumps(js)[:200] if js else "", bk))
        return 1
    st, js = api("GET", "/api/collections/users/auth-methods", None, None, call)
    names = [p.get("name") for p in ((js or {}).get("oauth2") or {}).get("providers", [])]
    print("providers offered on the login page now:", names)
    return 0 if "oidc" in names else 1


if __name__ == "__main__":
    sys.exit(main())
