"""
Hexis Channel System

Multi-channel messaging adapters that let users talk to the agent
from Discord, Telegram, and other platforms.
"""

from .base import (
    ChannelAdapter,
    ChannelCapabilities,
    ChannelMessage,
)
from .conversation import process_channel_message
from .manager import ChannelManager
from .media import Attachment

__all__ = [
    "Attachment",
    "ChannelAdapter",
    "ChannelCapabilities",
    "ChannelMessage",
    "ChannelManager",
    "process_channel_message",
]
