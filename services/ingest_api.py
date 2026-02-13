from __future__ import annotations

import asyncio
import queue
import threading
from pathlib import Path
from typing import Any, AsyncIterator
from uuid import uuid4

from core.agent_api import db_dsn_from_env
from services.ingest import Config, IngestionPipeline

_INGESTION_CANCEL: dict[str, threading.Event] = {}
_CANCEL_LOCK = threading.Lock()


def create_ingestion_session() -> str:
    session_id = str(uuid4())
    with _CANCEL_LOCK:
        _INGESTION_CANCEL[session_id] = threading.Event()
    return session_id


def cancel_ingestion(session_id: str) -> None:
    with _CANCEL_LOCK:
        event = _INGESTION_CANCEL.get(session_id)
    if event:
        event.set()


async def stream_ingestion(
    *,
    session_id: str,
    path: str,
    recursive: bool,
    llm_config: dict[str, Any],
    mode: str | None = None,
    min_importance: float | None = None,
    permanent: bool = False,
    base_trust: float | None = None,
) -> AsyncIterator[dict[str, Any]]:
    dsn = db_dsn_from_env()
    with _CANCEL_LOCK:
        cancel_event = _INGESTION_CANCEL.get(session_id) or threading.Event()
        _INGESTION_CANCEL[session_id] = cancel_event
    log_queue: queue.Queue[str | None] = queue.Queue()

    def log(message: str) -> None:
        log_queue.put(message)

    def run() -> None:
        config = Config(
            dsn=dsn,
            llm_config=llm_config,
            mode=mode or "fast",
            min_importance_floor=min_importance,
            permanent=permanent,
            base_trust=base_trust,
            verbose=True,
            log=log,
            cancel_check=cancel_event.is_set,
        )
        pipeline = IngestionPipeline(config)
        try:
            target = Path(path)
            if target.is_dir():
                pipeline.ingest_directory(target, recursive=recursive)
            else:
                pipeline.ingest_file(target)
            pipeline.print_stats()
        except Exception as exc:
            log(f"Error: {exc}")
        finally:
            pipeline.close()
            log_queue.put(None)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()

    loop = asyncio.get_running_loop()
    try:
        while True:
            line = await loop.run_in_executor(None, log_queue.get)
            if line is None:
                break
            yield {"type": "log", "text": line}
    finally:
        with _CANCEL_LOCK:
            _INGESTION_CANCEL.pop(session_id, None)
