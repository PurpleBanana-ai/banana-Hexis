"""
Hexis Channel System - Telegram Adapter

Connects to Telegram via bot token using python-telegram-bot.
Uses long-polling mode (works behind NAT, no webhook setup needed).
"""

from __future__ import annotations

import asyncio
import logging
import os
from typing import Any, Callable, Awaitable

from .base import ChannelAdapter, ChannelCapabilities, ChannelMessage
from .media import Attachment

logger = logging.getLogger(__name__)


def _resolve_token(config: dict[str, Any]) -> str | None:
    """Resolve Telegram bot token from config (env var name) or environment."""
    token_env = config.get("bot_token") or config.get("bot_token_env") or "TELEGRAM_BOT_TOKEN"
    token = os.getenv(str(token_env))
    if token:
        return token
    raw = config.get("bot_token", "")
    if raw and ":" in str(raw) and len(str(raw)) > 20:
        return str(raw)
    return None


class TelegramAdapter(ChannelAdapter):
    """
    Telegram channel adapter using python-telegram-bot.

    Config keys (from DB config table):
        channel.telegram.bot_token: env var name holding the bot token
        channel.telegram.allowed_chat_ids: JSON array of chat IDs, or "*"

    The bot responds to:
        - Private messages (always)
        - Group messages where the bot is mentioned (@botname)
        - Group messages in allowed chats
    """

    def __init__(self, config: dict[str, Any] | None = None) -> None:
        self._config = config or {}
        self._application = None
        self._on_message: Callable[[ChannelMessage], Awaitable[None]] | None = None
        self._connected = False
        self._bot_username: str | None = None
        self._allowed_chat_ids = self._parse_allowlist(self._config.get("allowed_chat_ids"))

    @staticmethod
    def _parse_allowlist(value: Any) -> set[str] | None:
        """Parse an allowlist value. Returns None for '*' (allow all)."""
        if value is None or value == "*":
            return None
        if isinstance(value, str):
            import json
            try:
                value = json.loads(value)
            except Exception:
                return {value}
        if isinstance(value, list):
            return {str(v) for v in value}
        return None

    @property
    def channel_type(self) -> str:
        return "telegram"

    @property
    def capabilities(self) -> ChannelCapabilities:
        return ChannelCapabilities(
            threads=False,
            reactions=True,
            media=True,
            typing_indicator=True,
            edit_message=True,
            max_message_length=4096,
        )

    @property
    def is_connected(self) -> bool:
        return self._connected

    async def start(
        self,
        on_message: Callable[[ChannelMessage], Awaitable[None]],
    ) -> None:
        try:
            from telegram import Update
            from telegram.ext import (
                Application,
                MessageHandler,
                filters,
            )
        except ImportError:
            raise RuntimeError(
                "python-telegram-bot is required for the Telegram adapter. "
                "Install it with: pip install python-telegram-bot"
            )

        token = _resolve_token(self._config)
        if not token:
            raise RuntimeError(
                "Telegram bot token not found. Set TELEGRAM_BOT_TOKEN env var "
                "or configure channel.telegram.bot_token in the database."
            )

        self._on_message = on_message

        application = Application.builder().token(token).build()
        self._application = application

        # Register message handler
        async def handle_message(update: Update, context) -> None:
            await self._handle_telegram_message(update)

        application.add_handler(
            MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message)
        )

        # Get bot info
        await application.initialize()
        bot_info = await application.bot.get_me()
        self._bot_username = bot_info.username
        self._connected = True
        logger.info(
            "Telegram connected as @%s (ID: %s)",
            bot_info.username,
            bot_info.id,
        )

        try:
            # Start polling (blocking)
            await application.start()
            await application.updater.start_polling(
                drop_pending_updates=True,
                allowed_updates=["message"],
            )

            # Keep running until cancelled
            while self._connected:
                await asyncio.sleep(1)

        except asyncio.CancelledError:
            pass
        finally:
            self._connected = False
            try:
                if application.updater and application.updater.running:
                    await application.updater.stop()
                if application.running:
                    await application.stop()
                await application.shutdown()
            except Exception:
                logger.debug("Telegram shutdown warning", exc_info=True)

    async def _handle_telegram_message(self, update) -> None:
        """Filter and normalize a Telegram message."""
        if not update.message:
            return

        message = update.message
        chat = message.chat
        user = message.from_user

        if not user:
            return

        # Accept text, photos, or documents
        has_text = bool(message.text or message.caption)
        has_media = bool(message.photo or message.document)
        if not has_text and not has_media:
            return

        is_private = chat.type == "private"
        raw_text = message.text or message.caption or ""

        if not is_private:
            # Check chat allowlist
            if self._allowed_chat_ids is not None:
                if str(chat.id) not in self._allowed_chat_ids:
                    # Still respond if mentioned
                    if self._bot_username and f"@{self._bot_username}" not in raw_text:
                        return

        # Strip bot mention from content
        content = raw_text
        if self._bot_username:
            content = content.replace(f"@{self._bot_username}", "").strip()

        if not content and not has_media:
            return

        # Convert Telegram attachments to Attachment instances
        attachments: list[Attachment] = []
        if message.photo:
            # Telegram provides multiple sizes; pick the largest
            photo = message.photo[-1]
            attachments.append(Attachment(
                url="",  # Telegram requires bot.get_file() to get the URL
                filename=f"photo_{photo.file_unique_id}.jpg",
                mime_type="image/jpeg",
                size=photo.file_size,
                platform_id=photo.file_id,
            ))
        if message.document:
            doc = message.document
            attachments.append(Attachment(
                url="",
                filename=doc.file_name or f"doc_{doc.file_unique_id}",
                mime_type=doc.mime_type,
                size=doc.file_size,
                platform_id=doc.file_id,
            ))

        sender_name = user.full_name or user.username or str(user.id)

        channel_msg = ChannelMessage(
            channel_type="telegram",
            channel_id=str(chat.id),
            sender_id=str(user.id),
            sender_name=sender_name,
            content=content or "",
            message_id=str(message.message_id),
            reply_to_id=str(message.reply_to_message.message_id) if message.reply_to_message else None,
            attachments=attachments,
            metadata={
                "chat_type": chat.type,
                "is_private": is_private,
                "username": user.username,
            },
        )

        if self._on_message:
            await self._on_message(channel_msg)

    async def stop(self) -> None:
        self._connected = False
        if self._application:
            try:
                if self._application.updater and self._application.updater.running:
                    await self._application.updater.stop()
                if self._application.running:
                    await self._application.stop()
                await self._application.shutdown()
            except Exception:
                logger.debug("Telegram stop warning", exc_info=True)
            self._application = None

    async def send(
        self,
        channel_id: str,
        text: str,
        *,
        reply_to: str | None = None,
        thread_id: str | None = None,
    ) -> str | None:
        if not self._application or not self._application.bot:
            logger.error("Telegram bot not connected")
            return None

        try:
            kwargs: dict[str, Any] = {
                "chat_id": int(channel_id),
                "text": text,
                "parse_mode": "Markdown",
            }
            if reply_to:
                kwargs["reply_to_message_id"] = int(reply_to)

            sent = await self._application.bot.send_message(**kwargs)
            return str(sent.message_id)

        except Exception:
            # Retry without Markdown in case of parse errors
            try:
                kwargs.pop("parse_mode", None)
                sent = await self._application.bot.send_message(**kwargs)
                return str(sent.message_id)
            except Exception:
                logger.exception("Failed to send Telegram message to %s", channel_id)
                return None

    async def send_typing(self, channel_id: str) -> None:
        if not self._application or not self._application.bot:
            return
        try:
            await self._application.bot.send_chat_action(
                chat_id=int(channel_id),
                action="typing",
            )
        except Exception:
            pass

    async def edit_message(
        self, channel_id: str, message_id: str, text: str,
    ) -> bool:
        if not self._application or not self._application.bot:
            return False
        try:
            await self._application.bot.edit_message_text(
                chat_id=int(channel_id),
                message_id=int(message_id),
                text=text,
                parse_mode="Markdown",
            )
            return True
        except Exception:
            # Retry without Markdown
            try:
                await self._application.bot.edit_message_text(
                    chat_id=int(channel_id),
                    message_id=int(message_id),
                    text=text,
                )
                return True
            except Exception:
                logger.exception("Failed to edit Telegram message %s", message_id)
                return False

    async def send_media(
        self,
        channel_id: str,
        attachment: Attachment,
        caption: str | None = None,
        *,
        reply_to: str | None = None,
    ) -> str | None:
        if not self._application or not self._application.bot:
            return None
        try:
            kwargs: dict[str, Any] = {"chat_id": int(channel_id)}
            if caption:
                kwargs["caption"] = caption
            if reply_to:
                kwargs["reply_to_message_id"] = int(reply_to)

            source = attachment.local_path or attachment.url
            if not source:
                return None

            is_image = attachment.mime_type and attachment.mime_type.startswith("image/")
            if is_image:
                sent = await self._application.bot.send_photo(photo=source, **kwargs)
            else:
                sent = await self._application.bot.send_document(document=source, **kwargs)
            return str(sent.message_id)
        except Exception:
            logger.exception("Failed to send Telegram media to %s", channel_id)
            return None
