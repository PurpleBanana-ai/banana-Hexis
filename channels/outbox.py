"""
Hexis Channel System - Outbox Consumer

Subscribes to the RabbitMQ outbox queue and routes heartbeat-initiated
messages to the appropriate channel adapters. This enables proactive
messaging — the agent can reach out to users without waiting for inbound.

Delivery modes:
    - direct: use explicit target_channel + target_id from payload
    - last_active: find the sender's most recent channel session
    - broadcast: send to all active sessions
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from typing import Any, TYPE_CHECKING

import requests

if TYPE_CHECKING:
    import asyncpg
    from .manager import ChannelManager

logger = logging.getLogger(__name__)

RABBITMQ_MANAGEMENT_URL = os.getenv("RABBITMQ_MANAGEMENT_URL", "http://rabbitmq:15672").rstrip("/")
RABBITMQ_USER = os.getenv("RABBITMQ_USER", "hexis")
RABBITMQ_PASSWORD = os.getenv("RABBITMQ_PASSWORD", "hexis_password")
RABBITMQ_VHOST = os.getenv("RABBITMQ_VHOST", "/")
RABBITMQ_OUTBOX_QUEUE = os.getenv("RABBITMQ_OUTBOX_QUEUE", "hexis.outbox")
POLL_INTERVAL = float(os.getenv("OUTBOX_POLL_INTERVAL", "2.0"))


class ChannelOutboxConsumer:
    """
    Polls the RabbitMQ outbox queue and routes messages to channel adapters.

    Usage:
        consumer = ChannelOutboxConsumer(manager, pool)
        await consumer.start()  # blocks until stop()
    """

    def __init__(self, manager: ChannelManager, pool: asyncpg.Pool) -> None:
        self._manager = manager
        self._pool = pool
        self._running = False

    async def start(self) -> None:
        """Poll the outbox queue until stopped."""
        self._running = True
        logger.info("Outbox consumer started")
        while self._running:
            try:
                count = await self._poll()
                if count > 0:
                    logger.info("Processed %d outbox message(s)", count)
            except asyncio.CancelledError:
                break
            except Exception:
                logger.exception("Outbox poll error")
            await asyncio.sleep(POLL_INTERVAL)

    async def stop(self) -> None:
        self._running = False

    async def _poll(self, max_messages: int = 10) -> int:
        """Fetch and process messages from the outbox queue."""
        vhost = _vhost_path()
        try:
            resp = await _rmq_request(
                "POST",
                f"/api/queues/{vhost}/{requests.utils.quote(RABBITMQ_OUTBOX_QUEUE, safe='')}/get",
                payload={
                    "count": max_messages,
                    "ackmode": "ack_requeue_false",
                    "encoding": "auto",
                    "truncate": 50000,
                },
            )
            if resp.status_code != 200:
                return 0
            msgs = resp.json()
            if not isinstance(msgs, list):
                return 0
        except Exception:
            return 0

        processed = 0
        for msg in msgs:
            raw_payload = msg.get("payload")
            try:
                body = json.loads(raw_payload) if isinstance(raw_payload, str) else raw_payload
            except Exception:
                continue

            if not isinstance(body, dict):
                continue

            try:
                await self._process_message(body)
                processed += 1
            except Exception:
                logger.exception("Failed to process outbox message: %s", str(body)[:200])

        return processed

    async def _process_message(self, body: dict[str, Any]) -> None:
        """Route an outbox message to the appropriate channel."""
        kind = body.get("kind", "")
        payload = body.get("payload", {})
        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except Exception:
                payload = {"content": payload}

        content = str(payload.get("content") or payload.get("message") or payload.get("text") or "")
        if not content:
            return

        delivery_mode = str(payload.get("delivery_mode") or "last_active")
        outbox_msg_id = str(body.get("id") or "")

        if delivery_mode == "direct":
            await self._deliver_direct(content, payload, outbox_msg_id)
        elif delivery_mode == "broadcast":
            await self._deliver_broadcast(content, payload, outbox_msg_id)
        else:
            # Default: last_active
            await self._deliver_last_active(content, payload, outbox_msg_id)

    async def _deliver_direct(self, content: str, payload: dict, outbox_msg_id: str) -> None:
        """Send to an explicit channel + target."""
        channel_type = str(payload.get("target_channel") or "")
        target_id = str(payload.get("target_id") or "")
        if not channel_type or not target_id:
            logger.warning("Direct delivery missing target_channel/target_id")
            return

        try:
            msg_id = await self._manager.send(channel_type, target_id, content)
            await self._log_delivery(outbox_msg_id, channel_type, target_id, None, content, "direct", True)
        except Exception as e:
            await self._log_delivery(outbox_msg_id, channel_type, target_id, None, content, "direct", False, str(e))

    async def _deliver_last_active(self, content: str, payload: dict, outbox_msg_id: str) -> None:
        """Send to the sender's most recently active channel session."""
        sender_id = str(payload.get("sender_id") or payload.get("target_user") or "")

        async with self._pool.acquire() as conn:
            if sender_id:
                row = await conn.fetchrow(
                    """
                    SELECT channel_type, channel_id, sender_id
                    FROM channel_sessions
                    WHERE sender_id = $1
                    ORDER BY last_active DESC NULLS LAST
                    LIMIT 1
                    """,
                    sender_id,
                )
            else:
                # No specific sender — use the globally most recent session
                row = await conn.fetchrow(
                    """
                    SELECT channel_type, channel_id, sender_id
                    FROM channel_sessions
                    ORDER BY last_active DESC NULLS LAST
                    LIMIT 1
                    """,
                )

        if not row:
            logger.warning("No active session found for last_active delivery")
            return

        channel_type = row["channel_type"]
        channel_id = row["channel_id"]
        resolved_sender = row["sender_id"]

        try:
            await self._manager.send(channel_type, channel_id, content)
            await self._log_delivery(outbox_msg_id, channel_type, channel_id, resolved_sender, content, "last_active", True)
        except Exception as e:
            await self._log_delivery(outbox_msg_id, channel_type, channel_id, resolved_sender, content, "last_active", False, str(e))

    async def _deliver_broadcast(self, content: str, payload: dict, outbox_msg_id: str) -> None:
        """Send to all active channel sessions."""
        async with self._pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT DISTINCT channel_type, channel_id, sender_id
                FROM channel_sessions
                WHERE last_active > CURRENT_TIMESTAMP - INTERVAL '7 days'
                ORDER BY channel_type, channel_id
                """,
            )

        for row in rows:
            channel_type = row["channel_type"]
            channel_id = row["channel_id"]
            sender_id = row["sender_id"]
            try:
                await self._manager.send(channel_type, channel_id, content)
                await self._log_delivery(outbox_msg_id, channel_type, channel_id, sender_id, content, "broadcast", True)
            except Exception as e:
                await self._log_delivery(outbox_msg_id, channel_type, channel_id, sender_id, content, "broadcast", False, str(e))

    async def _log_delivery(
        self,
        outbox_message_id: str,
        channel_type: str,
        channel_id: str,
        sender_id: str | None,
        content: str,
        delivery_mode: str,
        success: bool,
        error: str | None = None,
    ) -> None:
        """Log a delivery attempt to the channel_deliveries table."""
        try:
            async with self._pool.acquire() as conn:
                await conn.execute(
                    """
                    INSERT INTO channel_deliveries
                        (outbox_message_id, channel_type, channel_id, sender_id, content, delivery_mode, success, error)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                    """,
                    outbox_message_id or None,
                    channel_type,
                    channel_id,
                    sender_id,
                    content[:2000],  # Truncate for storage
                    delivery_mode,
                    success,
                    error,
                )
        except Exception:
            logger.debug("Failed to log delivery", exc_info=True)


def _vhost_path() -> str:
    if RABBITMQ_VHOST == "/":
        return "%2F"
    return requests.utils.quote(RABBITMQ_VHOST, safe="")


async def _rmq_request(method: str, path: str, payload: dict | None = None) -> requests.Response:
    url = f"{RABBITMQ_MANAGEMENT_URL}{path}"
    auth = (RABBITMQ_USER, RABBITMQ_PASSWORD)

    def _do() -> requests.Response:
        return requests.request(method, url, auth=auth, json=payload, timeout=5)

    return await asyncio.to_thread(_do)
