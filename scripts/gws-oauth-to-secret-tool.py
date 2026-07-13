#!/usr/bin/env python3
"""Obtain a Google OAuth refresh token and store it in secret-tool.

Reads client_id / client_secret from ~/.config/gws/client_secret.json (installed
app), runs the loopback authorization-code flow with access_type=offline, then
stores:

  secret-tool store --label='Google Workspace OAuth' service openshell key gws-client-id
  secret-tool store --label='Google Workspace OAuth' service openshell key gws-client-secret
  secret-tool store --label='Google Workspace OAuth' service openshell key gws-refresh-token

Optionally pushes the same values into the OpenShell `gws` provider.
"""

from __future__ import annotations

import argparse
import json
import secrets
import subprocess
import sys
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

DEFAULT_CLIENT_SECRET = Path.home() / ".config/gws/client_secret.json"
DEFAULT_SCOPES = [
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/drive.readonly",
    "openid",
    "email",
]


def load_client(path: Path) -> tuple[str, str, str]:
    data = json.loads(path.read_text())
    inst = data.get("installed") or data.get("web") or data
    client_id = inst.get("client_id")
    client_secret = inst.get("client_secret")
    token_uri = inst.get("token_uri", "https://oauth2.googleapis.com/token")
    if not client_id or not client_secret:
        raise SystemExit(f"missing client_id/client_secret in {path}")
    return client_id, client_secret, token_uri


def store_secret(label: str, key: str, value: str) -> None:
    """Store via secret-tool; value on stdin so it never lands in argv."""
    subprocess.run(
        [
            "secret-tool",
            "store",
            f"--label={label}",
            "service",
            "openshell",
            "key",
            key,
        ],
        input=value.encode(),
        check=True,
    )


def lookup_secret(key: str) -> str | None:
    out = subprocess.run(
        ["secret-tool", "lookup", "service", "openshell", "key", key],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        return None
    return out.stdout  # may include trailing newline from secret-tool


def exchange_code(
    token_uri: str,
    *,
    client_id: str,
    client_secret: str,
    code: str,
    redirect_uri: str,
) -> dict:
    body = urllib.parse.urlencode(
        {
            "code": code,
            "client_id": client_id,
            "client_secret": client_secret,
            "redirect_uri": redirect_uri,
            "grant_type": "authorization_code",
        }
    ).encode()
    req = urllib.request.Request(
        token_uri,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())


def run_oauth(
    *,
    client_id: str,
    client_secret: str,
    token_uri: str,
    scopes: list[str],
    bind_host: str,
    port: int,
) -> str:
    state = secrets.token_urlsafe(24)
    result: dict[str, str] = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            parsed = urllib.parse.urlparse(self.path)
            qs = urllib.parse.parse_qs(parsed.query)
            if qs.get("state", [None])[0] != state:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"state mismatch")
                return
            if "error" in qs:
                result["error"] = qs["error"][0]
                msg = f"error: {qs['error'][0]}"
            else:
                result["code"] = qs.get("code", [""])[0]
                msg = "Authorization complete. You can close this tab."
            body = f"<html><body><p>{msg}</p></body></html>".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):  # quiet
            return

    httpd = HTTPServer((bind_host, port), Handler)
    actual_port = httpd.server_address[1]
    # Google desktop clients accept http://localhost:<port>/ ; registered
    # redirect_uris often list bare http://localhost.
    redirect_uri = f"http://{bind_host}:{actual_port}/"
    auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode(
        {
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": " ".join(scopes),
            "access_type": "offline",
            # Force consent + do not union previously granted (write) scopes from
            # earlier gws logins — otherwise the screen shows compose/edit perms.
            "prompt": "consent",
            "state": state,
        }
    )

    print(f"Listening on {redirect_uri}")
    print("Opening browser for Google consent…")
    print(f"If it does not open, visit:\n  {auth_url}\n")
    webbrowser.open(auth_url)

    while "code" not in result and "error" not in result:
        httpd.handle_request()
    httpd.server_close()

    if "error" in result:
        raise SystemExit(f"OAuth error: {result['error']}")
    if not result.get("code"):
        raise SystemExit("no authorization code received")

    token = exchange_code(
        token_uri,
        client_id=client_id,
        client_secret=client_secret,
        code=result["code"],
        redirect_uri=redirect_uri,
    )
    refresh = token.get("refresh_token")
    if not refresh:
        raise SystemExit(
            "no refresh_token in response — revoke prior grants at "
            "https://myaccount.google.com/permissions and retry with prompt=consent"
        )
    print(
        f"Got tokens: refresh_len={len(refresh)} "
        f"access_len={len(token.get('access_token', ''))} "
        f"scope={token.get('scope', '')!r}"
    )
    return refresh


def update_openshell_provider(client_id: str, client_secret: str, refresh: str) -> None:
    subprocess.run(
        [
            "openshell",
            "provider",
            "update",
            "gws",
            "--credential",
            f"GWS_CLIENT_ID={client_id}",
            "--credential",
            f"GWS_CLIENT_SECRET={client_secret}",
            "--credential",
            f"GWS_REFRESH_TOKEN={refresh}",
        ],
        check=True,
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--client-secret",
        type=Path,
        default=DEFAULT_CLIENT_SECRET,
        help=f"path to client_secret.json (default: {DEFAULT_CLIENT_SECRET})",
    )
    ap.add_argument(
        "--scopes",
        nargs="+",
        default=DEFAULT_SCOPES,
        help="OAuth scopes (default: calendar/gmail/drive readonly)",
    )
    ap.add_argument("--host", default="localhost", help="loopback bind host")
    ap.add_argument(
        "--port",
        type=int,
        default=0,
        help="loopback port (0 = ephemeral)",
    )
    ap.add_argument(
        "--label",
        default="Google Workspace OAuth",
        help="secret-tool label",
    )
    ap.add_argument(
        "--update-provider",
        action="store_true",
        help="also openshell provider update gws with the new credentials",
    )
    ap.add_argument(
        "--from-secret-tool",
        action="store_true",
        help="skip browser flow; load existing secret-tool values and only "
        "optionally --update-provider (useful after a prior run)",
    )
    args = ap.parse_args()

    if not shutil_which("secret-tool"):
        raise SystemExit("secret-tool not found (libsecret)")

    if args.from_secret_tool:
        client_id = lookup_secret("gws-client-id")
        client_secret = lookup_secret("gws-client-secret")
        refresh = lookup_secret("gws-refresh-token")
        if not all([client_id, client_secret, refresh]):
            raise SystemExit("missing gws-* entries in secret-tool")
        # secret-tool may leave a trailing newline
        client_id, client_secret, refresh = (
            client_id.rstrip("\n"),
            client_secret.rstrip("\n"),
            refresh.rstrip("\n"),
        )
        print(
            f"Loaded from secret-tool: "
            f"id_len={len(client_id)} secret_len={len(client_secret)} "
            f"refresh_len={len(refresh)}"
        )
    else:
        client_id, client_secret, token_uri = load_client(args.client_secret)
        print(
            f"Using {args.client_secret}: "
            f"id_len={len(client_id)} secret_len={len(client_secret)}"
        )
        refresh = run_oauth(
            client_id=client_id,
            client_secret=client_secret,
            token_uri=token_uri,
            scopes=args.scopes,
            bind_host=args.host,
            port=args.port,
        )
        store_secret(args.label, "gws-client-id", client_id)
        store_secret(args.label, "gws-client-secret", client_secret)
        store_secret(args.label, "gws-refresh-token", refresh)
        print("Stored in secret-tool (service=openshell):")
        print("  key gws-client-id")
        print("  key gws-client-secret")
        print("  key gws-refresh-token")

    if args.update_provider:
        if not shutil_which("openshell"):
            raise SystemExit("openshell not found")
        update_openshell_provider(client_id, client_secret, refresh)
        print("Updated OpenShell provider gws")

    return 0


def shutil_which(cmd: str) -> str | None:
    from shutil import which

    return which(cmd)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\naborted", file=sys.stderr)
        raise SystemExit(130)
