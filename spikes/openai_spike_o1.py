#!/usr/bin/env python3
"""OpenAI/Codex spike O1: usage endpoint shape via the local Codex login, and
authorize-URL redirect_uri acceptance (ephemeral loopback port vs the pinned 1455).

Prints structural findings + usage numbers only. Never prints token values.
HTTPS goes through curl (framework Python here lacks SSL certs).
"""
import base64, hashlib, json, os, secrets, subprocess, sys, urllib.parse

AUTH = os.path.expanduser("~/.codex/auth.json")
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
UA = "ClaudeUsageBar/1.4.0-spike"

def b64url(raw): return base64.urlsafe_b64encode(raw).decode().rstrip("=")
def jwt_claims(tok):
    p = tok.split(".")[1]; p += "=" * (-len(p) % 4)
    return json.loads(base64.urlsafe_b64decode(p))
def curl(url, headers=(), data=None, method=None):
    cmd = ["curl", "-sS", "-o", "/dev/stderr", "-w", "%{http_code} %{redirect_url}", "-A", UA]
    for h in headers: cmd += ["-H", h]
    if data is not None: cmd += ["--data", data]
    if method: cmd += ["-X", method]
    cmd.append(url)
    r = subprocess.run(cmd, capture_output=True, text=True)
    code, _, redir = r.stdout.partition(" ")
    return int(code), redir, r.stderr

auth = json.load(open(AUTH))
t = auth["tokens"]
print("auth_mode:", auth.get("auth_mode"), "| last_refresh:", auth.get("last_refresh"))
idc = jwt_claims(t["id_token"]); acc = jwt_claims(t["access_token"])
print("id_token claims keys:", sorted(idc.keys()))
print("id_token auth ns:", {k: (v if k != 'user_id' else '<redacted>') for k, v in idc.get("https://api.openai.com/auth", {}).items()})
print("access_token claims keys:", sorted(acc.keys()), "| exp:", acc.get("exp"), "| iat:", acc.get("iat"))
print("access_token auth ns:", {k: (v if k not in ('user_id',) else '<redacted>') for k, v in acc.get("https://api.openai.com/auth", {}).items()})
print("account_id matches id_token chatgpt_account_id:", t["account_id"] == idc.get("https://api.openai.com/auth", {}).get("chatgpt_account_id"))

print("\n== usage endpoint (with ChatGPT-Account-Id) ==")
code, _, body = curl("https://chatgpt.com/backend-api/wham/usage",
                     [f"Authorization: Bearer {t['access_token']}", f"ChatGPT-Account-Id: {t['account_id']}"])
print("HTTP", code); print(body[:3000])
print("\n== usage endpoint (WITHOUT ChatGPT-Account-Id) ==")
code, _, body = curl("https://chatgpt.com/backend-api/wham/usage", [f"Authorization: Bearer {t['access_token']}"])
print("HTTP", code); print(body[:1500])
print("\n== credits endpoint ==")
code, _, body = curl("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
                     [f"Authorization: Bearer {t['access_token']}", f"ChatGPT-Account-Id: {t['account_id']}"])
print("HTTP", code); print(body[:1500])

print("\n== authorize URL acceptance (curl, no login) ==")
verifier = b64url(secrets.token_bytes(32)); challenge = b64url(hashlib.sha256(verifier.encode()).digest())
for redirect in ["http://localhost:1455/auth/callback", "http://localhost:50123/auth/callback", "http://localhost:50123/callback"]:
    params = {"response_type": "code", "client_id": CLIENT_ID, "redirect_uri": redirect,
              "scope": "openid profile email offline_access", "code_challenge": challenge,
              "code_challenge_method": "S256", "state": b64url(secrets.token_bytes(16)),
              "id_token_add_organizations": "true", "codex_cli_simplified_flow": "true", "originator": "codex_cli_rs"}
    url = "https://auth.openai.com/oauth/authorize?" + urllib.parse.urlencode(params)
    code, redir, body = curl(url)
    print(f"{redirect}: HTTP {code} redirect->{redir[:80]!r} body[:200]={body[:200]!r}")
