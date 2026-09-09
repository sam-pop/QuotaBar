#!/usr/bin/env python3
"""OpenAI/Codex spike O2: browser OAuth login (auth code + PKCE, Codex public client)
on a loopback port -> exchange -> usage endpoint with the new token -> refresh
rotation test. Usage: openai_spike_o2.py [port]  (0 = ephemeral, 1455 = Codex's pinned)

Prints structural findings only (keys, expiries, statuses). Never prints token/code
values. Grant persists chmod-600 OUTSIDE the repo for later re-checks.
HTTPS goes through curl (framework Python here lacks SSL certs).
"""
import base64, hashlib, http.server, json, os, secrets, socketserver, subprocess, sys, time, urllib.parse

CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
TOKEN_URL = "https://auth.openai.com/oauth/token"
UA = "ClaudeUsageBar/1.4.0-spike"
REQ_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0
OUT_DIR = os.path.expanduser("~/Library/Application Support/ClaudeUsageBarSpike")
GRANT_FILE = os.path.join(OUT_DIR, "openai_grant1.json")

def b64url(raw): return base64.urlsafe_b64encode(raw).decode().rstrip("=")
def jwt_claims(tok):
    p = tok.split(".")[1]; p += "=" * (-len(p) % 4)
    return json.loads(base64.urlsafe_b64decode(p))
def curl(url, headers=(), form=None):
    cmd = ["curl", "-sS", "-o", "/dev/stderr", "-w", "%{http_code}", "-A", UA]
    for h in headers: cmd += ["-H", h]
    if form is not None: cmd += ["--data", urllib.parse.urlencode(form)]
    cmd.append(url)
    r = subprocess.run(cmd, capture_output=True, text=True)
    return int(r.stdout), r.stderr

verifier = b64url(secrets.token_bytes(32))
challenge = b64url(hashlib.sha256(verifier.encode()).digest())
state = b64url(secrets.token_bytes(32))

class Handler(http.server.BaseHTTPRequestHandler):
    captured = {}
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(parsed.query)
        Handler.captured.setdefault("requests_seen", []).append(parsed.path)
        if parsed.path == "/auth/callback" and q.get("code") and q.get("state", [""])[0] == state:
            Handler.captured["code"] = q["code"][0]
            Handler.captured["extra_params"] = sorted(k for k in q if k not in ("code", "state"))
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
            self.wfile.write(b"<h2>Spike O2 succeeded &mdash; you can close this tab.</h2>")
        else:
            Handler.captured["bad_request"] = {"path": parsed.path, "keys": sorted(q.keys()), "error": q.get("error"), "desc": q.get("error_description")}
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass

socketserver.TCPServer.allow_reuse_address = True
server = socketserver.TCPServer(("127.0.0.1", REQ_PORT), Handler)
port = server.server_address[1]
redirect_uri = f"http://localhost:{port}/auth/callback"
params = {"response_type": "code", "client_id": CLIENT_ID, "redirect_uri": redirect_uri,
          "scope": "openid profile email offline_access", "code_challenge": challenge,
          "code_challenge_method": "S256", "state": state,
          "id_token_add_organizations": "true", "codex_cli_simplified_flow": "true", "originator": "codex_cli_rs"}
url = AUTHORIZE_URL + "?" + urllib.parse.urlencode(params)
print(f"redirect_uri={redirect_uri}"); print("opening browser…", flush=True)
print("AUTH_URL=" + url, flush=True) if os.environ.get("SPIKE_NO_OPEN") else subprocess.run(["open", url])
server.timeout = 1; deadline = time.time() + 240
while time.time() < deadline and "code" not in Handler.captured and "bad_request" not in Handler.captured:
    server.handle_request()
server.server_close()
print("callback capture:", {k: v for k, v in Handler.captured.items() if k != "code"})
if "code" not in Handler.captured: sys.exit("no code captured")

print("\n== exchange ==")
status, body = curl(TOKEN_URL, ["Content-Type: application/x-www-form-urlencoded"],
                    {"grant_type": "authorization_code", "client_id": CLIENT_ID, "code": Handler.captured["code"],
                     "redirect_uri": redirect_uri, "code_verifier": verifier})
print("HTTP", status)
try: tok = json.loads(body)
except Exception: print(body[:500]); sys.exit(1)
print("keys:", sorted(tok.keys()), "| expires_in:", tok.get("expires_in"), "| token_type:", tok.get("token_type"), "| scope:", tok.get("scope"))
if status != 200: print(body[:500]); sys.exit(1)
acc = jwt_claims(tok["access_token"]); print("access exp-iat (s):", acc["exp"] - acc["iat"], "| scp:", acc.get("scp"), "| client_id:", acc.get("client_id"))
idc = jwt_claims(tok["id_token"]); ns = idc.get("https://api.openai.com/auth", {})
print("id_token: email present:", "email" in idc, "| chatgpt_account_id present:", "chatgpt_account_id" in ns, "| plan:", ns.get("chatgpt_plan_type"))
os.makedirs(OUT_DIR, mode=0o700, exist_ok=True)
with open(GRANT_FILE, "w") as f: json.dump({"captured_at": time.time(), "tokens": tok}, f)
os.chmod(GRANT_FILE, 0o600)

print("\n== usage with new token (no account-id header) ==")
status, body = curl("https://chatgpt.com/backend-api/wham/usage", [f"Authorization: Bearer {tok['access_token']}"])
u = json.loads(body) if status == 200 else {}
print("HTTP", status, "| plan:", u.get("plan_type"), "| primary:", u.get("rate_limit", {}).get("primary_window"))

print("\n== refresh #1 (RT1 -> RT2) ==")
status, body = curl(TOKEN_URL, ["Content-Type: application/x-www-form-urlencoded"],
                    {"grant_type": "refresh_token", "client_id": CLIENT_ID, "refresh_token": tok["refresh_token"]})
r1 = json.loads(body) if status == 200 else {}
print("HTTP", status, "| keys:", sorted(r1.keys()), "| expires_in:", r1.get("expires_in"))
print("RT rotated (RT2 != RT1):", r1.get("refresh_token") not in (None, tok["refresh_token"]))
if status != 200: print(body[:400])

print("\n== refresh #2 with the OLD RT1 (does rotation invalidate it?) ==")
status, body = curl(TOKEN_URL, ["Content-Type: application/x-www-form-urlencoded"],
                    {"grant_type": "refresh_token", "client_id": CLIENT_ID, "refresh_token": tok["refresh_token"]})
print("HTTP", status, "| body:", body[:300] if status != 200 else "(200: old RT still works)")

print("\n== refresh #3 with RT2 (chain continues?) ==")
if r1.get("refresh_token"):
    status, body = curl(TOKEN_URL, ["Content-Type: application/x-www-form-urlencoded"],
                        {"grant_type": "refresh_token", "client_id": CLIENT_ID, "refresh_token": r1["refresh_token"]})
    print("HTTP", status)
    if status == 200:
        r2 = json.loads(body)
        with open(GRANT_FILE, "w") as f: json.dump({"captured_at": time.time(), "tokens": r2, "rt1": tok["refresh_token"]}, f)

print("\n== Codex's own auth.json token still works after our grant? ==")
cx = json.load(open(os.path.expanduser("~/.codex/auth.json")))["tokens"]
status, _ = curl("https://chatgpt.com/backend-api/wham/usage", [f"Authorization: Bearer {cx['access_token']}"])
print("HTTP", status)
