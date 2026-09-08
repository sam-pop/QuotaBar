#!/usr/bin/env python3
"""OpenAI/Codex spike O3 (run >= 24h after O2): does a PRE-rotation refresh token still
work a day after it was rotated? Drives the Import-from-Codex risk note (spec §6): if the
old token keeps working, the app's refresh chain and Codex CLI's can coexist after import.

Reads the grant O2 saved (chmod-600, outside the repo). Prints statuses only, never tokens.
Also refreshes the CURRENT chain once so the saved grant stays usable for later probes.
"""
import json, os, subprocess, sys, time, urllib.parse

CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
TOKEN_URL = "https://auth.openai.com/oauth/token"
UA = "ClaudeUsageBar/1.4.0-spike"
GRANT_FILE = os.path.expanduser("~/Library/Application Support/ClaudeUsageBarSpike/openai_grant1.json")

def curl(url, headers=(), form=None):
    cmd = ["curl", "-sS", "-o", "/dev/stderr", "-w", "%{http_code}", "-A", UA]
    for h in headers: cmd += ["-H", h]
    if form is not None: cmd += ["--data", urllib.parse.urlencode(form)]
    cmd.append(url)
    r = subprocess.run(cmd, capture_output=True, text=True)
    return int(r.stdout), r.stderr

g = json.load(open(GRANT_FILE))
age_h = (time.time() - g["captured_at"]) / 3600
print(f"grant age: {age_h:.1f} h")
if age_h < 24: sys.exit("too early — O3 needs >= 24h after O2")

print("\n== refresh with the PRE-rotation token (rt1), ~%.0fh after rotation ==" % age_h)
status, body = curl(TOKEN_URL, ["Content-Type: application/x-www-form-urlencoded"],
                    {"grant_type": "refresh_token", "client_id": CLIENT_ID, "refresh_token": g["rt1"]})
print("HTTP", status, "| body:" if status != 200 else "| (200: old token STILL works after a day)", body[:300] if status != 200 else "")

print("\n== refresh with the CURRENT chain (sanity) ==")
status, body = curl(TOKEN_URL, ["Content-Type: application/x-www-form-urlencoded"],
                    {"grant_type": "refresh_token", "client_id": CLIENT_ID, "refresh_token": g["tokens"]["refresh_token"]})
print("HTTP", status)
if status == 200:
    g["tokens"] = json.loads(body); g["last_o3_at"] = time.time()
    with open(GRANT_FILE, "w") as f: json.dump(g, f)
    os.chmod(GRANT_FILE, 0o600)
