import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import beszel_oidc as bo


class Pure(unittest.TestCase):
    def test_build_adds_oidc_and_keeps_the_rest(self):
        cur = {"providers": [{"name": "github", "clientId": "g"}], "enabled": False, "mappedFields": {"name": "name"}}
        n = bo.build_oauth2(cur, "beszel", "S3CRET")
        self.assertEqual([p["name"] for p in n["providers"]], ["github", "oidc"])
        self.assertTrue(n["enabled"])
        self.assertEqual(n["mappedFields"], {"name": "name"})
        self.assertEqual(cur["enabled"], False)                              # input untouched
        o = n["providers"][1]
        self.assertTrue(o["authURL"].endswith("/protocol/openid-connect/auth") and o["pkce"])

    def test_build_is_idempotent_and_replaces_old_oidc(self):
        n1 = bo.build_oauth2({}, "beszel", "A")
        n2 = bo.build_oauth2(n1, "beszel", "B")
        self.assertEqual(len([p for p in n2["providers"] if p["name"] == "oidc"]), 1)
        self.assertEqual(n2["providers"][0]["clientSecret"], "B")
        self.assertIn("mappedFields", n2)

    def test_redact(self):
        r = bo.redact({"providers": [{"name": "oidc", "clientSecret": "X", "clientId": "c"}]})
        self.assertEqual(r["providers"][0]["clientSecret"], "<redacted>")
        self.assertEqual(r["providers"][0]["clientId"], "c")


class FakeResp:
    def __init__(self, status, body):
        self.status, self._b = status, json.dumps(body).encode()

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class Flow(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.creds = os.path.join(self.d, "beszel.secret")
        with open(os.open(self.creds, os.O_WRONLY | os.O_CREAT, 0o600), "w") as fh:
            fh.write("admin@x.test\npw\n")
        self.state = {"oauth2": {"providers": [], "enabled": False}}
        self.calls = []

    def call(self, req, timeout=0):
        path, m = req.full_url.replace(bo.HUB, ""), req.get_method()
        self.calls.append((m, path))
        if path.endswith("auth-with-password"):
            return FakeResp(200, {"token": "T"})
        if m == "GET" and path == "/api/collections/users":
            return FakeResp(200, {"oauth2": self.state["oauth2"]})
        if m == "PATCH":
            self.state["oauth2"] = json.loads(req.data)["oauth2"]
            return FakeResp(200, {})
        if path.endswith("auth-methods"):
            return FakeResp(200, {"oauth2": {"providers": [{"name": p["name"]} for p in self.state["oauth2"]["providers"]]}})
        raise AssertionError(path)

    def test_dry_run_changes_nothing(self):
        self.assertEqual(bo.main(["--creds", self.creds, "--backup-dir", self.d], self.call, lambda p: "x"), 0)
        self.assertFalse(any(m == "PATCH" for m, _ in self.calls))

    def test_apply_backs_up_then_patches_and_verifies(self):
        rc = bo.main(["--apply", "--creds", self.creds, "--backup-dir", self.d], self.call, lambda p: "SECRET")
        self.assertEqual(rc, 0)
        self.assertEqual(self.state["oauth2"]["providers"][0]["name"], "oidc")
        backups = [f for f in os.listdir(self.d) if f.startswith("beszel-users-oauth2-")]
        self.assertEqual(len(backups), 1)
        self.assertEqual(oct(os.stat(os.path.join(self.d, backups[0])).st_mode & 0o777), "0o600")
        self.assertEqual(json.load(open(os.path.join(self.d, backups[0]))), {"providers": [], "enabled": False})   # the OLD state
        # restore puts it back
        self.assertEqual(bo.main(["--restore", os.path.join(self.d, backups[0]), "--creds", self.creds], self.call), 0)
        self.assertEqual(self.state["oauth2"], {"providers": [], "enabled": False})

    def test_empty_secret_changes_nothing(self):
        with self.assertRaises(SystemExit):
            bo.main(["--apply", "--creds", self.creds, "--backup-dir", self.d], self.call, lambda p: "  ")
        self.assertFalse(any(m == "PATCH" for m, _ in self.calls))

    def test_creds_must_be_private(self):
        os.chmod(self.creds, 0o644)
        with self.assertRaises(SystemExit):
            bo.main(["--creds", self.creds], self.call)


if __name__ == "__main__":
    unittest.main()
