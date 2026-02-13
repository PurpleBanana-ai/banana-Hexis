"""
Hexis Channel System - iMessage Adapter

Connects to iMessage via BlueBubbles server.
Inbound: Polling REST API.  Outbound: HTTP REST calls.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from typing import Any, Callable, Awaitable

from .base import ChannelAdapter, ChannelCapabilities, ChannelMessage, parse_allowlist, resolve_channel_token
from .media import Attachment

logger = logging.getLogger(__name__)

DEFAULT_API_URL = "http://localhost:1234"
POLL_INTERVAL = 2  # seconds


def _resolve_config(config: dict[str, Any], key: str, env_fallback: str) -> str | None:
    """Resolve a value from config or environment."""
    return resolve_channel_token(config, key, env_fallback)


class IMessageAdapter(ChannelAdapter):
    """
    iMessage channel adapter via BlueBubbles server.

    Config keys (from DB config table):
        channel.imessage.api_url: BlueBubbles server URL (default: http://localhost:1234)
        channel.imessage.password: BlueBubbles server password
        channel.imessage.allowed_handles: JSON array of phone/email handles, or "*"

    Requires a BlueBubbles server running on a Mac with iMessage configured.
    """

    def __init__(self, config: dict[str, Any] | None = None) -> None:
        self._config = config or {}
        self._on_message: Callable[[ChannelMessage], Awaitable[None]] | None = None
        self._connected = False
        self._api_url = str(
            self._config.get("api_url") or os.getenv("IMESSAGE_API_URL") or DEFAULT_API_URL
        ).rstrip("/")
        self._password: str | None = None
        self._allowed_handles = self._parse_allowlist(self._config.get("allowed_handles"))
        self._session = None
        self._last_timestamp: int = 0  # Unix timestamp ms for polling cursor

    @staticmethod
    def _parse_allowlist(value: Any) -> set[str] | None:
        return parse_allowlist(value)

    @property
    def channel_type(self) -> str:
        return "imessage"

    @property
    def capabilities(self) -> ChannelCapabilities:
        return ChannelCapabilities(
            threads=False,
            reactions=True,
            media=True,
            typing_indicator=True,
            edit_message=False,
            max_message_length=20000,
        )

    @property
    def is_connected(self) -> bool:
        return self._connected

    async def start(
        self,
        on_message: Callable[[ChannelMessage], Awaitable[None]],
    ) -> None:
        import aiohttp

        self._password = _resolve_config(self._config, "password", "IMESSAGE_PASSWORD")
        if not self._password:
            raise RuntimeError(
                "BlueBubbles password not found. Set IMESSAGE_PASSWORD env var "
                "or configure channel.imessage.password in the database."
            )

        self._on_message = on_message
        self._session = aiohttp.ClientSession()
        self._last_timestamp = int(time.time() * 1000)  # Start from now
        self._connected = True
        logger.info("iMessage adapter started via BlueBubbles at %s", self._api_url)

        try:
            await self._poll_loop()
        except asyncio.CancelledError:
            pass
        finally:
            self._connected = False
            if self._session and not self._session.closed:
                await self._session.close()
            self._session = None

    async def _poll_loop(self) -> None:
        """Poll BlueBubbles for new messages."""
        while self._connected:
            try:
                await self._poll_messages()
            except asyncio.CancelledError:
                break
            except Exception:
                logger.exception("iMessage poll error, retrying in %ds", POLL_INTERVAL)
            await asyncio.sleep(POLL_INTERVAL)

    async def _poll_messages(self) -> None:
        """Fetch new messages since last poll."""
        if not self._session or self._session.closed:
            return

        params = {
            "password": self._password,
            "limit": "50",
            "after": str(self._last_timestamp),
            "sort": "ASC",
            "with": "chats",  # Include chat metadata
        }

        try:
            async with self._session.get(
                f"{self._api_url}/api/v1/message",
                params=params,
                timeout=10,
            ) as resp:
                if resp.status != 200:
                    logger.warning("BlueBubbles poll failed: HTTP %d", resp.status)
                    return

                data = await resp.json()
                messages = data.get("data", [])

                for msg in messages:
                    await self._handle_message(msg)

                    # Update cursor
                    date_created = msg.get("dateCreated")
                    if date_created and date_created > self._last_timestamp:
                        self._last_timestamp = date_created

        except Exception:
            logger.exception("Error polling BlueBubbles messages")

    async def _handle_message(self, msg: dict) -> None:
        """Process a single BlueBubbles message."""
        # Skip messages sent by us (isFromMe)
        if msg.get("isFromMe"):
            return

        text = msg.get("text") or ""
        handle = msg.get("handle", {})
        sender_address = handle.get("address", "") if isinstance(handle, dict) else str(handle)

        if not sender_address:
            return

        # Check allowlist
        if self._allowed_handles is not None:
            if sender_address not in self._allowed_handles:
                return

        # Determine chat/channel ID from the first associated chat
        chats = msg.get("chats", [])
        chat_guid = chats[0].get("guid", sender_address) if chats else sender_address

        # Convert attachments
        attachments: list[Attachment] = []
        for att in msg.get("attachments", []):
            mime_type = att.get("mimeType") or att.get("uti")
            attachments.append(Attachment(
                url=f"{self._api_url}/api/v1/attachment/{att.get('guid', '')}/download?password={self._password}" if att.get("guid") else "",
                filename=att.get("transferName") or att.get("filename"),
                mime_type=mime_type,
                size=att.get("totalBytes"),
                platform_id=att.get("guid"),
            ))

        sender_name = handle.get("displayName") or sender_address if isinstance(handle, dict) else sender_address

        msg_guid = msg.get("guid", str(msg.get("dateCreated", "")))

        channel_msg = ChannelMessage(
            channel_type="imessage",
            channel_id=str(chat_guid),
            sender_id=sender_address,
            sender_name=sender_name,
            content=text,
            message_id=msg_guid,
            attachments=attachments,
            metadata={
                "is_group": bool(chats and chats[0].get("isGroup")),
                "service": msg.get("service", "iMessage"),
            },
        )

        if self._on_message:
            await self._on_message(channel_msg)

    async def stop(self) -> None:
        self._connected = False
        if self._session and not self._session.closed:
            await self._session.close()
        self._session = None

    async def send(
        self,
        channel_id: str,
        text: str,
        *,
        reply_to: str | None = None,
        thread_id: str | None = None,
    ) -> str | None:
        if not self._session or self._session.closed:
            logger.error("iMessage session not connected")
            return None

        try:
            payload: dict[str, Any] = {
                "chatGuid": channel_id,
                "message": text,
                "method": "apple-script",
            }

            params = {"password": self._password}

            async with self._session.post(
                f"{self._api_url}/api/v1/message/text",
                json=payload,
                params=params,
                timeout=30,
            ) as resp:
                if resp.status in (200, 201):
                    result = await resp.json()
                    data = result.get("data", {})
                    return data.get("guid") or str(data.get("dateCreated", ""))
                else:
                    body = await resp.text()
                    logger.error("iMessage send failed: HTTP %d: %s", resp.status, body[:200])
                    return None
        except Exception:
            logger.exception("Failed to send iMessage to %s", channel_id)
            return None

    async def send_typing(self, channel_id: str) -> None:
        """BlueBubbles supports typing indicators via API."""
        if not self._session or self._session.closed:
            return
        try:
            params = {"password": self._password}
            payload = {"chatGuid": channel_id}
            async with self._session.post(
                f"{self._api_url}/api/v1/chat/{channel_id}/typing",
                json=payload,
                params=params,
                timeout=5,
            ) as resp:
                pass  # Best effort
        except Exception:
            logger.debug("Silent exception in IMessageAdapter", exc_info=True)

    async def send_media(
        self,
        channel_id: str,
        attachment: Attachment,
        caption: str | None = None,
        *,
        reply_to: str | None = None,
    ) -> str | None:
        if not self._session or self._session.closed:
            return None

        try:
            import aiohttp

            params = {"password": self._password}

            data = aiohttp.FormData()
            data.add_field("chatGuid", channel_id)
            if caption:
                data.add_field("message", caption)

            if attachment.local_path:
                data.add_field(
                    "attachment",
                    open(attachment.local_path, "rb"),
                    filename=attachment.filename or "attachment",
                    content_type=attachment.mime_type or "application/octet-stream",
                )
            elif attachment.url:
                # Download first, then upload
                from .media import download_attachment
                downloaded = await download_attachment(attachment)
                if downloaded.local_path:
                    data.add_field(
                        "attachment",
                        open(downloaded.local_path, "rb"),
                        filename=downloaded.filename or "attachment",
                        content_type=downloaded.mime_type or "application/octet-stream",
                    )
                else:
                    return None
            else:
                return None

            async with self._session.post(
                f"{self._api_url}/api/v1/message/attachment",
                data=data,
                params=params,
                timeout=60,
            ) as resp:
                if resp.status in (200, 201):
                    result = await resp.json()
                    msg_data = result.get("data", {})
                    return msg_data.get("guid")
                else:
                    body = await resp.text()
                    logger.error("iMessage send_media failed: HTTP %d: %s", resp.status, body[:200])
                    return None
        except Exception:
            logger.exception("Failed to send iMessage media to %s", channel_id)
            return None
