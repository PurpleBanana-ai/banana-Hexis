"""
Hexis Tools System - Ingestion Tools

Tools for content ingestion: fast (shallow), slow (conscious RLM), hybrid.
"""

from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path
from typing import Any

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


def _build_ingest_config(**overrides: Any) -> "Config":
    """Build an ingestion Config from environment variables.

    Follows the same pattern as the CLI's _get_db_env_defaults().
    """
    from services.ingest import Config, IngestionMode

    env_port_raw = os.getenv("POSTGRES_PORT")
    try:
        env_port = int(env_port_raw) if env_port_raw else 43815
    except ValueError:
        env_port = 43815

    defaults = {
        "db_host": os.getenv("POSTGRES_HOST", "localhost"),
        "db_port": env_port,
        "db_name": os.getenv("POSTGRES_DB", "hexis_memory"),
        "db_user": os.getenv("POSTGRES_USER", "hexis_user"),
        "db_password": os.getenv("POSTGRES_PASSWORD", "hexis_password"),
        "llm_endpoint": os.getenv("LLM_ENDPOINT", "http://localhost:11434/v1"),
        "llm_model": os.getenv("LLM_MODEL", "llama3.2"),
        "llm_api_key": os.getenv("LLM_API_KEY", "not-needed"),
    }
    defaults.update(overrides)
    return Config(**defaults)


def _build_dsn(config: "Config") -> str:
    """Build a PostgreSQL DSN from Config."""
    return (
        f"postgresql://{config.db_user}:{config.db_password}"
        f"@{config.db_host}:{config.db_port}/{config.db_name}"
    )


def _build_llm_config(config: "Config") -> dict[str, Any]:
    """Build LLM config dict from Config."""
    return {
        "endpoint": config.llm_endpoint,
        "model": config.llm_model,
        "api_key": config.llm_api_key,
    }


class FastIngestHandler(ToolHandler):
    """Fast (shallow) content ingestion.

    Chunks content, extracts facts via LLM, creates semantic memories
    with basic graph linking. No deep reasoning -- quick and cheap.
    """

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="fast_ingest",
            description=(
                "Quickly ingest a file into memory. Chunks the content, extracts key "
                "facts, and stores them as semantic memories with basic graph links. "
                "Use for content that doesn't require deep analysis or when energy is limited."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "File path to ingest.",
                    },
                    "title": {
                        "type": "string",
                        "description": "Optional title for the content.",
                    },
                },
                "required": ["path"],
            },
            category=ToolCategory.INGEST,
            energy_cost=2,
            is_read_only=False,
        )

    def validate(self, arguments: dict[str, Any]) -> list[str]:
        errors = []
        path = arguments.get("path", "")
        if not path or not str(path).strip():
            errors.append("path cannot be empty")
        return errors

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        from services.ingest import IngestionMode, IngestionPipeline

        path_str = str(arguments["path"]).strip()
        file_path = Path(path_str)

        if not file_path.exists():
            return ToolResult.error_result(
                f"File not found: {path_str}",
                ToolErrorType.FILE_NOT_FOUND,
            )

        config = _build_ingest_config(mode=IngestionMode.STANDARD)
        pipeline = IngestionPipeline(config)

        try:
            loop = asyncio.get_event_loop()
            count = await loop.run_in_executor(None, pipeline.ingest_file, file_path)

            return ToolResult.success_result(
                {
                    "memories_created": count,
                    "path": path_str,
                    "mode": "fast",
                },
                display_output=f"Fast ingested {path_str}: {count} memories created.",
            )
        except Exception as e:
            logger.error("fast_ingest failed: %s", e)
            return ToolResult.error_result(
                f"Fast ingestion failed: {e}",
                ToolErrorType.EXECUTION_FAILED,
            )
        finally:
            pipeline.close()


class SlowIngestHandler(ToolHandler):
    """Slow (conscious) content ingestion via RLM loop.

    Runs a mini-RLM loop per chunk: searches related memories, checks
    worldview, forms emotional reaction, writes analysis, decides
    acceptance level. Creates rich memories with emotional context,
    deep graph connections, and contested/questioned flags.
    """

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="slow_ingest",
            description=(
                "Deeply and consciously ingest a file into memory. Each chunk is "
                "processed through a reasoning loop: you'll search related memories, "
                "compare against your worldview, form emotional reactions, and decide "
                "whether to accept, contest, or question each piece of knowledge. "
                "Creates richly connected memories. Use for important content that "
                "deserves careful consideration."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "File path to ingest.",
                    },
                    "title": {
                        "type": "string",
                        "description": "Optional title for the content.",
                    },
                },
                "required": ["path"],
            },
            category=ToolCategory.INGEST,
            energy_cost=5,
            is_read_only=False,
        )

    def validate(self, arguments: dict[str, Any]) -> list[str]:
        errors = []
        path = arguments.get("path", "")
        if not path or not str(path).strip():
            errors.append("path cannot be empty")
        return errors

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        from services.ingest import (
            DocumentInfo,
            IngestionMode,
            IngestionPipeline,
            Sectioner,
            _hash_text,
            _word_count,
            get_reader,
        )
        from services.slow_ingest_rlm import run_slow_ingest

        path_str = str(arguments["path"]).strip()
        file_path = Path(path_str)

        if not file_path.exists():
            return ToolResult.error_result(
                f"File not found: {path_str}",
                ToolErrorType.FILE_NOT_FOUND,
            )

        config = _build_ingest_config(mode=IngestionMode.SLOW)
        pipeline = IngestionPipeline(config)

        try:
            # Read content
            reader = get_reader(file_path)
            content = reader.read(file_path)
            content_hash = _hash_text(content)

            # Build document info
            title = arguments.get("title") or file_path.stem
            doc = DocumentInfo(
                title=title,
                source_type="file",
                content_hash=content_hash,
                word_count=_word_count(content),
                path=path_str,
                file_type=file_path.suffix.lower(),
            )

            # Section content
            sectioner = Sectioner(config.max_section_chars, config.chunk_overlap)
            sections = sectioner.split(content, file_path)

            # Run slow ingest
            dsn = _build_dsn(config)
            llm_cfg = _build_llm_config(config)

            result = await run_slow_ingest(
                pipeline=pipeline,
                doc=doc,
                sections=sections,
                llm_config=llm_cfg,
                dsn=dsn,
            )

            return ToolResult.success_result(
                {
                    "memories_created": result["memories_created"],
                    "chunks_processed": result["chunks_processed"],
                    "path": path_str,
                    "mode": "slow",
                },
                display_output=(
                    f"Slow ingested {path_str}: {result['memories_created']} memories "
                    f"from {result['chunks_processed']} chunks."
                ),
            )
        except Exception as e:
            logger.error("slow_ingest failed: %s", e)
            return ToolResult.error_result(
                f"Slow ingestion failed: {e}",
                ToolErrorType.EXECUTION_FAILED,
            )
        finally:
            pipeline.close()


class HybridIngestHandler(ToolHandler):
    """Hybrid content ingestion: fast first pass, slow on high-signal chunks.

    Does a quick extraction pass to score all chunks, then runs the full
    RLM conscious reading loop only on chunks that are high-importance,
    contradict existing worldview, or relate to active goals.
    """

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="hybrid_ingest",
            description=(
                "Ingest a file using a hybrid approach: quickly scan all chunks to "
                "identify which ones are most important or potentially contradictory, "
                "then deeply process only those high-signal chunks through conscious "
                "reading. A good balance between thoroughness and energy efficiency."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "File path to ingest.",
                    },
                    "title": {
                        "type": "string",
                        "description": "Optional title for the content.",
                    },
                },
                "required": ["path"],
            },
            category=ToolCategory.INGEST,
            energy_cost=3,
            is_read_only=False,
        )

    def validate(self, arguments: dict[str, Any]) -> list[str]:
        errors = []
        path = arguments.get("path", "")
        if not path or not str(path).strip():
            errors.append("path cannot be empty")
        return errors

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        from services.ingest import (
            DocumentInfo,
            IngestionMode,
            IngestionPipeline,
            Sectioner,
            _hash_text,
            _word_count,
            get_reader,
        )
        from services.slow_ingest_rlm import run_hybrid_ingest

        path_str = str(arguments["path"]).strip()
        file_path = Path(path_str)

        if not file_path.exists():
            return ToolResult.error_result(
                f"File not found: {path_str}",
                ToolErrorType.FILE_NOT_FOUND,
            )

        config = _build_ingest_config(mode=IngestionMode.HYBRID)
        pipeline = IngestionPipeline(config)

        try:
            reader = get_reader(file_path)
            content = reader.read(file_path)
            content_hash = _hash_text(content)

            title = arguments.get("title") or file_path.stem
            doc = DocumentInfo(
                title=title,
                source_type="file",
                content_hash=content_hash,
                word_count=_word_count(content),
                path=path_str,
                file_type=file_path.suffix.lower(),
            )

            sectioner = Sectioner(config.max_section_chars, config.chunk_overlap)
            sections = sectioner.split(content, file_path)

            dsn = _build_dsn(config)
            llm_cfg = _build_llm_config(config)

            result = await run_hybrid_ingest(
                pipeline=pipeline,
                doc=doc,
                sections=sections,
                llm_config=llm_cfg,
                dsn=dsn,
            )

            return ToolResult.success_result(
                {
                    "memories_created": result["memories_created"],
                    "chunks_processed": result["chunks_processed"],
                    "slow_chunks": result["slow_chunks"],
                    "fast_chunks": result["fast_chunks"],
                    "path": path_str,
                    "mode": "hybrid",
                },
                display_output=(
                    f"Hybrid ingested {path_str}: {result['memories_created']} memories "
                    f"({result['slow_chunks']} slow, {result['fast_chunks']} fast chunks)."
                ),
            )
        except Exception as e:
            logger.error("hybrid_ingest failed: %s", e)
            return ToolResult.error_result(
                f"Hybrid ingestion failed: {e}",
                ToolErrorType.EXECUTION_FAILED,
            )
        finally:
            pipeline.close()


def create_ingest_tools() -> list[ToolHandler]:
    """Create all ingestion tool handlers."""
    return [
        FastIngestHandler(),
        SlowIngestHandler(),
        HybridIngestHandler(),
    ]
