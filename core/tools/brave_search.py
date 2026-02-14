"""
Hexis Tools System - Brave Search Integration (E.8)

Web search tool using the Brave Search API.
Auth via X-Subscription-Token header.
"""

from __future__ import annotations

import logging
from typing import Any, Callable

from .base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)
from .api_keys import resolve_api_key

logger = logging.getLogger(__name__)

_BASE_URL = "https://api.search.brave.com"


class BraveSearchHandler(ToolHandler):
    """Search the web using the Brave Search API."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="brave_search",
            description="Search the web using Brave Search. Returns titles, URLs, and descriptions.",
            parameters={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query",
                    },
                    "count": {
                        "type": "integer",
                        "description": "Number of results to return (default 5, max 20)",
                    },
                },
                "required": ["query"],
            },
            category=ToolCategory.WEB,
            energy_cost=2,
            is_read_only=True,
            optional=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        token = await resolve_api_key(
            context,
            explicit_resolver=self._api_key_resolver,
            config_key="brave_search",
            env_names=("BRAVE_SEARCH_API_KEY",),
        )
        if not token:
            return ToolResult.error_result(
                "Brave Search API key not configured. Set BRAVE_SEARCH_API_KEY.",
                ToolErrorType.AUTH_FAILED,
            )

        try:
            import httpx
        except ImportError:
            return ToolResult.error_result(
                "httpx not installed. Run: pip install httpx",
                ToolErrorType.MISSING_DEPENDENCY,
            )

        query = arguments["query"]
        count = arguments.get("count", 5)

        headers = {
            "X-Subscription-Token": token,
            "Accept": "application/json",
        }

        try:
            async with httpx.AsyncClient() as client:
                resp = await client.get(
                    f"{_BASE_URL}/res/v1/web/search",
                    headers=headers,
                    params={"q": query, "count": count},
                    timeout=15,
                )
                resp.raise_for_status()
                data = resp.json()

            results = []
            for r in data.get("web", {}).get("results", []):
                results.append({
                    "title": r.get("title"),
                    "url": r.get("url"),
                    "description": r.get("description", ""),
                })

            return ToolResult.success_result(
                {"results": results, "count": len(results)},
                display_output=f"Found {len(results)} result(s) for '{query}'",
            )
        except Exception as e:
            return ToolResult.error_result(f"Brave Search API error: {e}")


def create_brave_search_tools(
    api_key_resolver: Callable[[], str | None] | None = None,
) -> list[ToolHandler]:
    """Create Brave Search tools."""
    return [
        BraveSearchHandler(api_key_resolver),
    ]
