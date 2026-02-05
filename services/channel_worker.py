"""
Hexis Channel Worker Service

Stateless service that runs channel adapters (Discord, Telegram, etc.)
and routes messages through the conversation pipeline.

Usage:
    hexis-channels                    # Start all configured channels
    hexis-channels --channel discord  # Start only Discord
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal

import asyncpg
from dotenv import load_dotenv

from core.agent_api import db_dsn_from_env

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("channel_worker")


async def _load_channel_config(conn: asyncpg.Connection, channel_type: str) -> dict:
    """Load channel config from the DB config table."""
    prefix = f"channel.{channel_type}."
    rows = await conn.fetch(
        "SELECT key, value FROM config WHERE key LIKE $1",
        prefix + "%",
    )
    config: dict = {}
    for row in rows:
        key = str(row["key"]).removeprefix(prefix)
        value = row["value"]
        # Try to parse JSON values
        if isinstance(value, str):
            try:
                value = json.loads(value)
            except Exception:
                pass
        config[key] = value
    return config


async def run_channel_worker(
    channels: list[str] | None = None,
    instance: str | None = None,
) -> None:
    """
    Main entry point for the channel worker.

    Args:
        channels: List of channel types to start, or None for all configured.
        instance: Target a specific Hexis instance.
    """
    from channels.manager import ChannelManager

    dsn = db_dsn_from_env(instance)
    pool = await asyncpg.create_pool(dsn=dsn, min_size=2, max_size=10)
    logger.info("Connected to database")

    manager = ChannelManager(pool)

    # Load and register configured channels
    async with pool.acquire() as conn:
        # Check if agent is configured
        is_ready = await conn.fetchval("SELECT is_agent_configured() AND is_init_complete()")
        if not is_ready:
            logger.warning("Agent not configured. Run 'hexis init' first.")

        # Discord
        if channels is None or "discord" in channels:
            discord_config = await _load_channel_config(conn, "discord")
            if discord_config.get("bot_token") or os.getenv("DISCORD_BOT_TOKEN"):
                try:
                    from channels.discord_adapter import DiscordAdapter
                    adapter = DiscordAdapter(discord_config)
                    manager.register(adapter)
                except ImportError:
                    logger.warning("discord.py not installed, skipping Discord channel")
            else:
                logger.info("Discord not configured (no bot_token), skipping")

        # Telegram
        if channels is None or "telegram" in channels:
            telegram_config = await _load_channel_config(conn, "telegram")
            if telegram_config.get("bot_token") or os.getenv("TELEGRAM_BOT_TOKEN"):
                try:
                    from channels.telegram_adapter import TelegramAdapter
                    adapter = TelegramAdapter(telegram_config)
                    manager.register(adapter)
                except ImportError:
                    logger.warning("python-telegram-bot not installed, skipping Telegram channel")
            else:
                logger.info("Telegram not configured (no bot_token), skipping")

        # Slack
        if channels is None or "slack" in channels:
            slack_config = await _load_channel_config(conn, "slack")
            if slack_config.get("bot_token") or os.getenv("SLACK_BOT_TOKEN"):
                try:
                    from channels.slack_adapter import SlackAdapter
                    adapter = SlackAdapter(slack_config)
                    manager.register(adapter)
                except ImportError:
                    logger.warning("slack-bolt not installed, skipping Slack channel")
            else:
                logger.info("Slack not configured (no bot_token), skipping")

        # Signal
        if channels is None or "signal" in channels:
            signal_config = await _load_channel_config(conn, "signal")
            if signal_config.get("phone_number") or os.getenv("SIGNAL_PHONE_NUMBER"):
                from channels.signal_adapter import SignalAdapter
                adapter = SignalAdapter(signal_config)
                manager.register(adapter)
            else:
                logger.info("Signal not configured (no phone_number), skipping")

        # WhatsApp
        if channels is None or "whatsapp" in channels:
            whatsapp_config = await _load_channel_config(conn, "whatsapp")
            if whatsapp_config.get("access_token") or os.getenv("WHATSAPP_ACCESS_TOKEN"):
                from channels.whatsapp_adapter import WhatsAppAdapter
                adapter = WhatsAppAdapter(whatsapp_config)
                manager.register(adapter)
            else:
                logger.info("WhatsApp not configured (no access_token), skipping")

        # iMessage (via BlueBubbles)
        if channels is None or "imessage" in channels:
            imessage_config = await _load_channel_config(conn, "imessage")
            if imessage_config.get("password") or os.getenv("IMESSAGE_PASSWORD"):
                from channels.imessage_adapter import IMessageAdapter
                adapter = IMessageAdapter(imessage_config)
                manager.register(adapter)
            else:
                logger.info("iMessage not configured (no BlueBubbles password), skipping")

        # Matrix
        if channels is None or "matrix" in channels:
            matrix_config = await _load_channel_config(conn, "matrix")
            if matrix_config.get("access_token") or os.getenv("MATRIX_ACCESS_TOKEN"):
                try:
                    from channels.matrix_adapter import MatrixAdapter
                    adapter = MatrixAdapter(matrix_config)
                    manager.register(adapter)
                except ImportError:
                    logger.warning("matrix-nio not installed, skipping Matrix channel")
            else:
                logger.info("Matrix not configured (no access_token), skipping")

    if not manager.adapters:
        logger.error(
            "No channels configured. Set environment variables for your channel "
            "(e.g. DISCORD_BOT_TOKEN, SLACK_BOT_TOKEN, TELEGRAM_BOT_TOKEN) "
            "or configure channel.* keys in the database."
        )
        await pool.close()
        return

    # Set up graceful shutdown
    stop_event = asyncio.Event()

    def shutdown_handler(sig, frame):
        logger.info("Received %s, shutting down...", signal.Signals(sig).name)
        stop_event.set()

    signal.signal(signal.SIGINT, shutdown_handler)
    signal.signal(signal.SIGTERM, shutdown_handler)

    # Start all adapters
    logger.info("Starting %d channel adapter(s)...", len(manager.adapters))
    await manager.start_all()

    # Start outbox consumer as a background task
    outbox_consumer = None
    outbox_task = None
    try:
        from channels.outbox import ChannelOutboxConsumer
        outbox_consumer = ChannelOutboxConsumer(manager, pool)
        outbox_task = asyncio.create_task(
            outbox_consumer.start(),
            name="outbox-consumer",
        )
        logger.info("Outbox consumer started")
    except Exception:
        logger.warning("Failed to start outbox consumer", exc_info=True)

    # Wait for shutdown signal
    await stop_event.wait()

    # Graceful shutdown
    logger.info("Stopping channel adapters...")
    if outbox_consumer:
        await outbox_consumer.stop()
    if outbox_task:
        outbox_task.cancel()
        try:
            await outbox_task
        except asyncio.CancelledError:
            pass
    await manager.stop_all()
    await pool.close()
    logger.info("Channel worker stopped")


def main() -> int:
    """CLI entry point for hexis-channels."""
    p = argparse.ArgumentParser(
        prog="hexis-channels",
        description="Run Hexis channel adapters (Discord, Telegram, etc.)",
    )
    p.add_argument(
        "--channel", "-c",
        action="append",
        choices=["discord", "telegram", "slack", "signal", "whatsapp", "imessage", "matrix"],
        help="Start only specific channel(s). Can be repeated. Default: all configured.",
    )
    p.add_argument(
        "--instance", "-i",
        default=os.getenv("HEXIS_INSTANCE"),
        help="Target a specific instance.",
    )
    args = p.parse_args()
    asyncio.run(run_channel_worker(channels=args.channel, instance=args.instance))
    return 0


if __name__ == "__main__":
    main()
