"""Google Gemini CLI OAuth (Cloud Code Assist) auth module."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlencode

import httpx

from core.auth.utils import advisory_lock_key, generate_pkce, needs_refresh, now_ms

# Constants (from OpenClaw extensions/google-gemini-cli-auth/oauth.ts)
GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
GOOGLE_USERINFO_URL = "https://www.googleapis.com/oauth2/v1/userinfo?alt=json"
GOOGLE_CODE_ASSIST_ENDPOINT = "https://cloudcode-pa.googleapis.com"

GEMINI_CLI_REDIRECT_URI = "http://localhost:8085/oauth2callback"
GEMINI_CLI_SCOPES = [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
]

GEMINI_CLI_CONFIG_KEY = "oauth.google_gemini_cli"
_GEMINI_CLI_LOCK_KEY = advisory_lock_key(GEMINI_CLI_CONFIG_KEY)


def _get_client_credentials() -> tuple[str, str]:
    """Resolve client ID and secret from env vars or raise."""
    client_id = os.getenv("GEMINI_CLI_OAUTH_CLIENT_ID") or os.getenv("OPENCLAW_GEMINI_OAUTH_CLIENT_ID")
    client_secret = os.getenv("GEMINI_CLI_OAUTH_CLIENT_SECRET") or os.getenv("OPENCLAW_GEMINI_OAUTH_CLIENT_SECRET")
    if not client_id or not client_secret:
        raise RuntimeError(
            "Google Gemini CLI OAuth requires GEMINI_CLI_OAUTH_CLIENT_ID and "
            "GEMINI_CLI_OAUTH_CLIENT_SECRET environment variables."
        )
    return client_id, client_secret


@dataclass(frozen=True)
class GeminiCliCredentials:
    access: str
    refresh: str
    expires_ms: int
    project_id: str
    email: str | None = None


def build_authorize_url(*, challenge: str, state: str) -> str:
    client_id, _ = _get_client_credentials()
    params = {
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": GEMINI_CLI_REDIRECT_URI,
        "scope": " ".join(GEMINI_CLI_SCOPES),
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
        "access_type": "offline",
        "prompt": "consent",
    }
    return f"{GOOGLE_AUTH_URL}?{urlencode(params)}"


async def exchange_code(*, code: str, verifier: str) -> dict[str, Any]:
    """Exchange authorization code for tokens. Returns raw token response."""
    client_id, client_secret = _get_client_credentials()
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(
            GOOGLE_TOKEN_URL,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": GEMINI_CLI_REDIRECT_URI,
                "code_verifier": verifier,
            },
        )
    if resp.status_code < 200 or resp.status_code >= 300:
        raise RuntimeError(f"Google token exchange failed: HTTP {resp.status_code}: {resp.text}")
    return resp.json()


async def refresh_access_token(refresh_token: str) -> tuple[str, int]:
    """Refresh Google OAuth token. Returns (access_token, expires_ms)."""
    client_id, client_secret = _get_client_credentials()
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(
            GOOGLE_TOKEN_URL,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
            },
        )
    if resp.status_code < 200 or resp.status_code >= 300:
        raise RuntimeError(f"Google token refresh failed: HTTP {resp.status_code}: {resp.text}")
    data = resp.json()
    access = data.get("access_token")
    expires_in = data.get("expires_in", 3600)
    if not isinstance(access, str):
        raise RuntimeError("Google token refresh: missing access_token.")
    return access, now_ms() + int(expires_in) * 1000


async def fetch_user_email(access_token: str) -> str | None:
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(
                GOOGLE_USERINFO_URL,
                headers={"Authorization": f"Bearer {access_token}"},
            )
        if resp.status_code == 200:
            return resp.json().get("email")
    except Exception:
        pass
    return None


async def discover_project(access_token: str) -> str:
    """Discover or onboard Cloud Code Assist project."""
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        "User-Agent": "google-api-nodejs-client/9.15.1",
        "X-Goog-Api-Client": "google-cloud-sdk vscode_cloudshelleditor/0.1",
        "Client-Metadata": json.dumps({
            "ideType": "IDE_UNSPECIFIED",
            "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI",
        }),
    }
    body = json.dumps({
        "metadata": {
            "ideType": "IDE_UNSPECIFIED",
            "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI",
        },
    })

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                f"{GOOGLE_CODE_ASSIST_ENDPOINT}/v1internal:loadCodeAssist",
                headers=headers,
                content=body,
            )
        if resp.status_code == 200:
            data = resp.json()
            project = data.get("cloudaicompanionProject")
            if isinstance(project, str):
                return project
            if isinstance(project, dict) and project.get("id"):
                return project["id"]
    except Exception:
        pass

    # Fallback: check env
    env_project = os.getenv("GOOGLE_CLOUD_PROJECT")
    if env_project:
        return env_project

    raise RuntimeError(
        "Could not discover Cloud Code Assist project. "
        "Set GOOGLE_CLOUD_PROJECT env var or ensure your Google account has Cloud Code Assist enabled."
    )


async def complete_login(code: str, verifier: str) -> GeminiCliCredentials:
    """Exchange code, fetch email, discover project — full login."""
    token_data = await exchange_code(code=code, verifier=verifier)
    access = token_data["access_token"]
    refresh = token_data.get("refresh_token", "")
    expires_in = token_data.get("expires_in", 3600)
    expires_ms = now_ms() + int(expires_in) * 1000

    email = await fetch_user_email(access)
    project_id = await discover_project(access)

    return GeminiCliCredentials(
        access=access,
        refresh=refresh,
        expires_ms=expires_ms,
        project_id=project_id,
        email=email,
    )


# ---------------------------------------------------------------------------
# DB persistence
# ---------------------------------------------------------------------------

def credentials_to_dict(creds: GeminiCliCredentials) -> dict[str, Any]:
    d: dict[str, Any] = {
        "access": creds.access,
        "refresh": creds.refresh,
        "expires_ms": creds.expires_ms,
        "project_id": creds.project_id,
    }
    if creds.email:
        d["email"] = creds.email
    return d


def credentials_from_value(value: Any) -> GeminiCliCredentials | None:
    if value is None:
        return None
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except Exception:
            return None
    if not isinstance(value, dict):
        return None
    access = value.get("access")
    refresh = value.get("refresh", "")
    expires_ms = value.get("expires_ms")
    project_id = value.get("project_id")
    if not isinstance(access, str) or not isinstance(project_id, str):
        return None
    if not isinstance(expires_ms, (int, float)):
        return None
    return GeminiCliCredentials(
        access=access,
        refresh=refresh,
        expires_ms=int(expires_ms),
        project_id=project_id,
        email=value.get("email"),
    )


async def load_credentials(conn) -> GeminiCliCredentials | None:
    value = await conn.fetchval("SELECT get_config($1)", GEMINI_CLI_CONFIG_KEY)
    return credentials_from_value(value)


async def save_credentials(conn, creds: GeminiCliCredentials) -> None:
    await conn.execute(
        "SELECT set_config($1, $2::jsonb)",
        GEMINI_CLI_CONFIG_KEY,
        json.dumps(credentials_to_dict(creds)),
    )


async def delete_credentials(conn) -> None:
    await conn.execute("SELECT delete_config_key($1)", GEMINI_CLI_CONFIG_KEY)


async def ensure_fresh_credentials(conn, *, skew_seconds: int = 300) -> GeminiCliCredentials:
    async with conn.transaction():
        await conn.execute("SELECT pg_advisory_xact_lock($1)", _GEMINI_CLI_LOCK_KEY)
        creds = await load_credentials(conn)
        if not creds:
            raise RuntimeError("Google Gemini CLI is not configured. Run: `hexis auth google-gemini-cli login`")
        if not needs_refresh(creds.expires_ms, skew_seconds):
            return creds
        if not creds.refresh:
            raise RuntimeError("Google Gemini CLI credentials expired and no refresh token. Re-login required.")
        access, expires_ms = await refresh_access_token(creds.refresh)
        refreshed = GeminiCliCredentials(
            access=access,
            refresh=creds.refresh,
            expires_ms=expires_ms,
            project_id=creds.project_id,
            email=creds.email,
        )
        await save_credentials(conn, refreshed)
        return refreshed
