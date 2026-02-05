"""Stub-only memory access for RLM REPL syscalls.

Uses psycopg2 (sync) to match the existing MemoryToolHandler pattern.
All methods are synchronous -- designed to be called from exec() in the REPL.
"""

from __future__ import annotations

import json
import logging
from typing import Any

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    psycopg2 = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)


class MemoryRepo:
    """Sync memory access for RLM environments."""

    def __init__(self, dsn: str):
        self._dsn = dsn
        self._conn = None

    def _get_conn(self):
        if psycopg2 is None:
            raise RuntimeError("psycopg2 is required for MemoryRepo")
        if self._conn is None or self._conn.closed:
            self._conn = psycopg2.connect(self._dsn)
            self._conn.autocommit = True
            psycopg2.extras.register_uuid()
        return self._conn

    def search_stubs(
        self,
        query: str,
        *,
        limit: int = 20,
        types: list[str] | None = None,
        min_importance: float = 0.0,
        preview_chars: int = 256,
    ) -> list[dict[str, Any]]:
        """Search memories, return stubs only (no full content)."""
        conn = self._get_conn()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            type_array = types if types else None
            cur.execute(
                "SELECT * FROM recall_memories_stub(%s, %s, %s, %s, %s)",
                (query, limit, type_array, min_importance, preview_chars),
            )
            rows = cur.fetchall()
            return [_serialize_row(row) for row in rows]

    def fetch_by_ids(
        self, ids: list[str], *, max_chars: int = 2000
    ) -> list[dict[str, Any]]:
        """Fetch full memory content by IDs with truncation."""
        if not ids:
            return []
        conn = self._get_conn()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT * FROM get_memories_by_ids(%s::uuid[], %s)",
                (ids, max_chars),
            )
            rows = cur.fetchall()
            return [_serialize_row(row) for row in rows]

    def recent_stubs(
        self, *, limit: int = 5, preview_chars: int = 256
    ) -> list[dict[str, Any]]:
        """Get recent episodic memory stubs."""
        conn = self._get_conn()
        with conn.cursor() as cur:
            cur.execute(
                "SELECT get_recent_context_stub(%s, %s)", (limit, preview_chars)
            )
            result = cur.fetchone()[0]
            if result is None:
                return []
            return json.loads(result) if isinstance(result, str) else result

    def contradictions_stub(
        self, *, limit: int = 5, preview_chars: int = 256
    ) -> list[dict[str, Any]]:
        """Get contradiction pairs as stubs."""
        conn = self._get_conn()
        with conn.cursor() as cur:
            cur.execute(
                "SELECT get_contradictions_stub(%s, %s)", (limit, preview_chars)
            )
            result = cur.fetchone()[0]
            if result is None:
                return []
            return json.loads(result) if isinstance(result, str) else result

    def touch(self, ids: list[str]) -> None:
        """Mark memories as accessed (updates access_count/last_accessed)."""
        if not ids:
            return
        conn = self._get_conn()
        with conn.cursor() as cur:
            cur.execute("SELECT touch_memories(%s)", (ids,))

    def close(self) -> None:
        if self._conn and not self._conn.closed:
            self._conn.close()
            self._conn = None


def _serialize_row(row: dict) -> dict[str, Any]:
    """Ensure all values are JSON-serializable."""
    out = {}
    for k, v in dict(row).items():
        if hasattr(v, "isoformat"):
            out[k] = v.isoformat()
        elif hasattr(v, "hex"):
            out[k] = str(v)
        else:
            out[k] = v
    return out
