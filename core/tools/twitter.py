"""
Hexis Tools System - Twitter/X Research (E.6)

Tool for searching tweets using the free FxTwitter API.
Falls back to a helpful error message if the API is unavailable.
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

logger = logging.getLogger(__name__)

_FXTWITTER_BASE = "https://api.fxtwitter.com"


class SearchTwitterHandler(ToolHandler):
    """Search tweets using the free FxTwitter API."""

    def __init__(self, api_key_resolver: Callable[[], str | None] | None = None):
        # Kept for interface consistency; FxTwitter is free/unauthenticated
        self._api_key_resolver = api_key_resolver

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="twitter_search",
            description=(
                "Search Twitter/X for recent tweets matching a query. "
                "Uses the free FxTwitter API (no API key required)."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query",
                    },
                    "max_results": {
                        "type": "integer",
                        "description": "Maximum number of tweets to return (default 10)",
                    },
                },
                "required": ["query"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=2,
            is_read_only=True,
            optional=True,
        )

    async def execute(self, arguments: dict[str, Any], context: ToolExecutionContext) -> ToolResult:
        try:
            import httpx
        except ImportError:
            return ToolResult.error_result(
                "httpx not installed. Run: pip install httpx",
                ToolErrorType.MISSING_DEPENDENCY,
            )

        query = arguments["query"]
        max_results = arguments.get("max_results", 10)

        try:
            async with httpx.AsyncClient() as client:
                resp = await client.get(
                    f"{_FXTWITTER_BASE}/search",
                    params={"query": query},
                    timeout=15,
                )
                resp.raise_for_status()
                data = resp.json()

            tweets_raw = data.get("tweets", data.get("results", []))
            tweets = []
            for t in tweets_raw[:max_results]:
                author = t.get("author", {})
                tweets.append({
                    "id": t.get("id"),
                    "text": t.get("text", ""),
                    "author": author.get("screen_name") or author.get("name", "unknown"),
                    "created_at": t.get("created_at"),
                    "metrics": {
                        "likes": t.get("likes", 0),
                        "retweets": t.get("retweets", 0),
                        "replies": t.get("replies", 0),
                    },
                })

            return ToolResult.success_result(
                {"tweets": tweets, "count": len(tweets)},
                display_output=f"Found {len(tweets)} tweet(s) for '{query}'",
            )
        except Exception as e:
            logger.warning("FxTwitter search failed: %s", e)
            return ToolResult.error_result(
                f"Twitter search unavailable. Try searching manually at "
                f"https://x.com/search?q={query} -- Error: {e}"
            )


def create_twitter_tools(
    api_key_resolver: Callable[[], str | None] | None = None,
) -> list[ToolHandler]:
    """Create Twitter/X research tools."""
    return [
        SearchTwitterHandler(api_key_resolver),
    ]
