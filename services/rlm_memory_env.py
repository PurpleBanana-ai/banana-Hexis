"""RLM memory syscalls and workspace management.

Provides REPL-callable functions for two-stage memory retrieval
(stub search -> selective fetch) with workspace budgets.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Callable

from core.memory_repo import MemoryRepo

logger = logging.getLogger(__name__)


@dataclass
class WorkspaceBudgets:
    max_loaded_memories: int = 25
    max_loaded_chars: int = 20_000
    max_notes_chars: int = 8_000
    max_per_memory_chars: int = 2_000


@dataclass
class WorkspaceMetrics:
    search_count: int = 0
    fetch_count: int = 0
    fetched_chars_total: int = 0
    summarize_events: int = 0


@dataclass
class RLMWorkspace:
    task: str = ""
    turn_snapshot: dict[str, Any] = field(default_factory=dict)
    memory_stubs: list[dict] = field(default_factory=list)
    loaded_memories: list[dict] = field(default_factory=list)
    notes: str = ""
    metrics: WorkspaceMetrics = field(default_factory=WorkspaceMetrics)
    budgets: WorkspaceBudgets = field(default_factory=WorkspaceBudgets)


class RLMMemoryEnv:
    """
    Provides REPL-callable syscalls for memory access.

    All functions are synchronous (called from exec() in the REPL sandbox).
    """

    def __init__(
        self,
        repo: MemoryRepo,
        workspace: RLMWorkspace,
        llm_query_fn: Callable[[str], str] | None = None,
    ):
        self._repo = repo
        self._workspace = workspace
        self._llm_query = llm_query_fn

    # ------------------------------------------------------------------
    # Memory search (stubs only)
    # ------------------------------------------------------------------

    def memory_search(
        self,
        query: str,
        *,
        limit: int = 20,
        types: list[str] | None = None,
        min_importance: float = 0.0,
    ) -> list[dict]:
        """Search memories. Returns stubs (id + preview), not full content."""
        stubs = self._repo.search_stubs(
            query,
            limit=limit,
            types=types,
            min_importance=min_importance,
            preview_chars=256,
        )
        self._workspace.memory_stubs = stubs
        self._workspace.metrics.search_count += 1
        logger.debug(
            "memory_search: query=%r returned %d stubs", query[:60], len(stubs)
        )
        return stubs

    # ------------------------------------------------------------------
    # Memory fetch (full content, with budgets)
    # ------------------------------------------------------------------

    def memory_fetch(
        self, ids: list[str], *, max_chars: int | None = None
    ) -> list[dict]:
        """Fetch full memory content. Respects workspace budgets."""
        if max_chars is None:
            max_chars = self._workspace.budgets.max_per_memory_chars

        memories = self._repo.fetch_by_ids(ids, max_chars=max_chars)

        self._workspace.loaded_memories.extend(memories)
        self._workspace.metrics.fetch_count += 1
        chars = sum(len(m.get("content", "")) for m in memories)
        self._workspace.metrics.fetched_chars_total += chars

        self._enforce_budgets()
        self._repo.touch(ids)

        logger.debug(
            "memory_fetch: fetched %d memories (%d chars)", len(memories), chars
        )
        return memories

    # ------------------------------------------------------------------
    # Workspace management
    # ------------------------------------------------------------------

    def workspace_summarize(
        self,
        bucket: str = "loaded_memories",
        *,
        into: str = "notes",
        max_chars: int | None = None,
    ) -> str:
        """Summarize a workspace bucket using sub-LLM call."""
        if max_chars is None:
            max_chars = self._workspace.budgets.max_notes_chars

        if bucket == "loaded_memories":
            content = "\n\n".join(
                f"[{m.get('type', '?')}] {m.get('content', '')}"
                for m in self._workspace.loaded_memories
            )
        else:
            content = self._workspace.notes

        if not content:
            return ""

        if self._llm_query:
            summary = self._llm_query(
                f"Summarize the following memories concisely. "
                f"Keep key facts, dates, and relationships. "
                f"Max {max_chars} chars.\n\n{content}"
            )
        else:
            # Fallback: simple truncation
            summary = content[:max_chars]

        if into == "notes":
            self._workspace.notes = summary[:max_chars]

        self._workspace.metrics.summarize_events += 1
        return summary[:max_chars]

    def workspace_drop(
        self,
        bucket: str = "loaded_memories",
        *,
        keep_ids: list[str] | None = None,
    ) -> None:
        """Drop workspace bucket contents, optionally keeping specific IDs."""
        if bucket == "loaded_memories":
            if keep_ids:
                keep_set = set(str(i) for i in keep_ids)
                self._workspace.loaded_memories = [
                    m
                    for m in self._workspace.loaded_memories
                    if str(m.get("id")) in keep_set
                ]
            else:
                self._workspace.loaded_memories = []
        elif bucket == "notes":
            self._workspace.notes = ""

    def workspace_status(self) -> dict[str, Any]:
        """Return current workspace sizes and budget usage."""
        loaded_chars = sum(
            len(m.get("content", "")) for m in self._workspace.loaded_memories
        )
        return {
            "loaded_memories_count": len(self._workspace.loaded_memories),
            "loaded_memories_chars": loaded_chars,
            "notes_chars": len(self._workspace.notes),
            "stubs_count": len(self._workspace.memory_stubs),
            "budgets": {
                "max_loaded_memories": self._workspace.budgets.max_loaded_memories,
                "max_loaded_chars": self._workspace.budgets.max_loaded_chars,
                "max_notes_chars": self._workspace.budgets.max_notes_chars,
            },
            "metrics": {
                "search_count": self._workspace.metrics.search_count,
                "fetch_count": self._workspace.metrics.fetch_count,
                "fetched_chars_total": self._workspace.metrics.fetched_chars_total,
                "summarize_events": self._workspace.metrics.summarize_events,
            },
        }

    # ------------------------------------------------------------------
    # Budget enforcement
    # ------------------------------------------------------------------

    def _enforce_budgets(self) -> None:
        """Auto-summarize and drop if budgets exceeded."""
        b = self._workspace.budgets
        loaded = self._workspace.loaded_memories

        # Count-based enforcement
        if len(loaded) > b.max_loaded_memories:
            logger.info(
                "Workspace budget exceeded: %d/%d memories, auto-summarizing",
                len(loaded),
                b.max_loaded_memories,
            )
            self.workspace_summarize("loaded_memories", into="notes")
            excess = len(loaded) - b.max_loaded_memories
            self._workspace.loaded_memories = loaded[excess:]

        # Char-based enforcement
        total_chars = sum(len(m.get("content", "")) for m in self._workspace.loaded_memories)
        if total_chars > b.max_loaded_chars:
            logger.info(
                "Workspace char budget exceeded: %d/%d chars, auto-summarizing",
                total_chars,
                b.max_loaded_chars,
            )
            self.workspace_summarize("loaded_memories", into="notes")
            while (
                total_chars > b.max_loaded_chars
                and self._workspace.loaded_memories
            ):
                removed = self._workspace.loaded_memories.pop(0)
                total_chars -= len(removed.get("content", ""))

    # ------------------------------------------------------------------
    # REPL integration
    # ------------------------------------------------------------------

    def get_repl_functions(self) -> dict[str, Any]:
        """Return dict of functions to inject into REPL namespace."""
        return {
            "memory_search": self.memory_search,
            "memory_fetch": self.memory_fetch,
            "workspace_summarize": self.workspace_summarize,
            "workspace_drop": self.workspace_drop,
            "workspace_status": self.workspace_status,
        }
