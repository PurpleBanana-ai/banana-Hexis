"""Tests for core.providers.anthropic_http — HTTP Anthropic Messages client."""

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from core.providers.anthropic_http import (
    _build_headers,
    _convert_tools,
    _parse_response,
    anthropic_http_completion,
    stream_anthropic_http_completion,
)

pytestmark = pytest.mark.core


def test_build_headers_api_key():
    h = _build_headers("sk-test", "api-key")
    assert h["x-api-key"] == "sk-test"
    assert "Authorization" not in h
    assert h["anthropic-version"] == "2023-06-01"


def test_build_headers_setup_token():
    h = _build_headers("sk-ant-oat01-abc", "setup-token")
    assert h["Authorization"] == "Bearer sk-ant-oat01-abc"
    assert "x-api-key" not in h
    assert "anthropic-beta" in h
    assert "x-app" in h


def test_convert_tools_empty():
    assert _convert_tools(None) == []
    assert _convert_tools([]) == []


def test_convert_tools_format():
    tools = [{
        "type": "function",
        "function": {
            "name": "recall",
            "description": "Search memory",
            "parameters": {"type": "object", "properties": {"q": {"type": "string"}}},
        },
    }]
    result = _convert_tools(tools)
    assert len(result) == 1
    assert result[0]["name"] == "recall"
    assert result[0]["description"] == "Search memory"
    assert "input_schema" in result[0]


def test_parse_response_text_only():
    data = {
        "content": [
            {"type": "text", "text": "Hello "},
            {"type": "text", "text": "world"},
        ]
    }
    result = _parse_response(data)
    assert result["content"] == "Hello world"
    assert result["tool_calls"] == []


def test_parse_response_with_tool_use():
    data = {
        "content": [
            {"type": "text", "text": "Let me search."},
            {
                "type": "tool_use",
                "id": "tu_1",
                "name": "recall",
                "input": {"query": "hello"},
            },
        ]
    }
    result = _parse_response(data)
    assert result["content"] == "Let me search."
    assert len(result["tool_calls"]) == 1
    assert result["tool_calls"][0]["id"] == "tu_1"
    assert result["tool_calls"][0]["name"] == "recall"
    assert result["tool_calls"][0]["arguments"] == {"query": "hello"}


@pytest.mark.asyncio
async def test_anthropic_http_completion_non_streaming():
    """Test non-streaming completion with mocked httpx."""
    response_body = {
        "content": [{"type": "text", "text": "Test response"}],
        "model": "claude-sonnet-4-20250514",
        "stop_reason": "end_turn",
    }

    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = response_body

    mock_client = AsyncMock()
    mock_client.post.return_value = mock_response
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)

    with patch("core.providers.anthropic_http.httpx.AsyncClient", return_value=mock_client):
        result = await anthropic_http_completion(
            endpoint="https://api.anthropic.com",
            api_key="sk-ant-oat01-test",
            model="claude-sonnet-4-20250514",
            messages=[{"role": "user", "content": "Hello"}],
            tools=None,
            auth_mode="setup-token",
        )

    assert result["content"] == "Test response"
    assert result["tool_calls"] == []
    # Verify the headers
    call_kwargs = mock_client.post.call_args
    headers = call_kwargs.kwargs.get("headers") or call_kwargs[1].get("headers", {})
    assert "Bearer" in headers.get("Authorization", "")


@pytest.mark.asyncio
async def test_anthropic_http_error_raises():
    """Test that non-2xx response raises RuntimeError."""
    mock_response = MagicMock()
    mock_response.status_code = 401
    mock_response.text = "Unauthorized"

    mock_client = AsyncMock()
    mock_client.post.return_value = mock_response
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)

    with patch("core.providers.anthropic_http.httpx.AsyncClient", return_value=mock_client):
        with pytest.raises(RuntimeError, match="401"):
            await anthropic_http_completion(
                endpoint="https://api.anthropic.com",
                api_key="bad-key",
                model="claude-sonnet-4-20250514",
                messages=[{"role": "user", "content": "Hello"}],
                tools=None,
            )
