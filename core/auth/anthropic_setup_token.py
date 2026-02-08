"""Anthropic setup-token (Claude Code CLI subscription) auth module."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

# Validation constants (from OpenClaw src/commands/auth-token.ts)
ANTHROPIC_SETUP_TOKEN_PREFIX = "sk-ant-oat01-"
ANTHROPIC_SETUP_TOKEN_MIN_LENGTH = 80

ANTHROPIC_SETUP_TOKEN_CONFIG_KEY = "token.anthropic_setup_token"


@dataclass(frozen=True)
class AnthropicSetupTokenCredentials:
    token: str


def validate_setup_token(token: str) -> str | None:
    """Return an error message if the token is invalid, else None."""
    if not token:
        return "Token is empty."
    if not token.startswith(ANTHROPIC_SETUP_TOKEN_PREFIX):
        return f"Token must start with '{ANTHROPIC_SETUP_TOKEN_PREFIX}'."
    if len(token) < ANTHROPIC_SETUP_TOKEN_MIN_LENGTH:
        return f"Token is too short (min {ANTHROPIC_SETUP_TOKEN_MIN_LENGTH} chars)."
    return None


def credentials_to_dict(creds: AnthropicSetupTokenCredentials) -> dict[str, Any]:
    return {"token": creds.token}


def credentials_from_value(value: Any) -> AnthropicSetupTokenCredentials | None:
    if value is None:
        return None
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except Exception:
            return None
    if not isinstance(value, dict):
        return None
    token = value.get("token")
    if not isinstance(token, str) or not token:
        return None
    return AnthropicSetupTokenCredentials(token=token)


def load_credentials() -> AnthropicSetupTokenCredentials | None:
    from core.auth.store import load_auth
    return credentials_from_value(load_auth(ANTHROPIC_SETUP_TOKEN_CONFIG_KEY))


def save_credentials(creds: AnthropicSetupTokenCredentials) -> None:
    from core.auth.store import save_auth
    save_auth(ANTHROPIC_SETUP_TOKEN_CONFIG_KEY, credentials_to_dict(creds))


def delete_credentials() -> None:
    from core.auth.store import delete_auth
    delete_auth(ANTHROPIC_SETUP_TOKEN_CONFIG_KEY)
