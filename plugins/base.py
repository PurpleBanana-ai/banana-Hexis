"""
Hexis Plugin System - Base Types

Defines the plugin interface and the API object plugins receive.
"""

from __future__ import annotations

import json
import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, TYPE_CHECKING

from core.tools.base import ToolHandler, ToolSpec
from core.tools.hooks import HookEvent, HookHandler

if TYPE_CHECKING:
    import asyncpg


@dataclass
class PluginManifest:
    """Plugin metadata and configuration schema."""

    id: str
    name: str
    version: str = "0.0.0"
    description: str = ""
    config_schema: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "PluginManifest":
        return cls(
            id=str(data.get("id", "")),
            name=str(data.get("name", "")),
            version=str(data.get("version", "0.0.0")),
            description=str(data.get("description", "")),
            config_schema=dict(data.get("config_schema", {})),
        )

    @classmethod
    def from_json_file(cls, path: Path) -> "PluginManifest":
        """Load manifest from a plugin.json file."""
        text = path.read_text(encoding="utf-8")
        data = json.loads(text)
        return cls.from_dict(data)

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "version": self.version,
            "description": self.description,
            "config_schema": self.config_schema,
        }


@dataclass
class _RegisteredTool:
    """Internal: a tool handler registered by a plugin."""
    handler: ToolHandler
    optional: bool


@dataclass
class _RegisteredHook:
    """Internal: a hook registered by a plugin."""
    event: HookEvent
    handler: HookHandler


class _OptionalToolWrapper(ToolHandler):
    """Wraps a ToolHandler to force its spec.optional = True."""

    def __init__(self, inner: ToolHandler):
        self._inner = inner
        self._spec: ToolSpec | None = None

    @property
    def spec(self) -> ToolSpec:
        if self._spec is None:
            from dataclasses import replace
            self._spec = replace(self._inner.spec, optional=True)
        return self._spec

    async def execute(self, arguments: dict[str, Any], context: Any) -> Any:
        return await self._inner.execute(arguments, context)

    def validate(self, arguments: dict[str, Any]) -> list[str]:
        return self._inner.validate(arguments)


class HexisPluginApi:
    """
    API object passed to plugins during registration.

    Provides methods to register tools, hooks, and skills.
    Plugins use this to declare their capabilities without
    directly touching the tool registry.
    """

    def __init__(
        self,
        plugin_id: str,
        pool: "asyncpg.Pool",
        plugin_config: dict[str, Any] | None = None,
    ):
        self._plugin_id = plugin_id
        self._pool = pool
        self._plugin_config = plugin_config or {}
        self._logger = logging.getLogger(f"plugin.{plugin_id}")
        self._tools: list[_RegisteredTool] = []
        self._hooks: list[_RegisteredHook] = []
        self._skill_dirs: list[Path] = []

    @property
    def plugin_id(self) -> str:
        return self._plugin_id

    @property
    def pool(self) -> "asyncpg.Pool":
        """Database connection pool."""
        return self._pool

    @property
    def config(self) -> dict[str, Any]:
        """Plugin-specific configuration from the database."""
        return self._plugin_config

    @property
    def logger(self) -> logging.Logger:
        """Namespaced logger for this plugin."""
        return self._logger

    def register_tool(self, handler: ToolHandler, *, optional: bool = False) -> None:
        """
        Register a tool handler.

        Args:
            handler: Tool handler implementing ToolHandler
            optional: If True, tool requires explicit allowlist inclusion
        """
        if optional:
            handler = _OptionalToolWrapper(handler)
        self._tools.append(_RegisteredTool(handler=handler, optional=optional))
        self._logger.debug("Registered tool: %s (optional=%s)", handler.spec.name, optional)

    def register_hook(self, event: HookEvent, handler: HookHandler) -> None:
        """Register a lifecycle hook."""
        self._hooks.append(_RegisteredHook(event=event, handler=handler))
        self._logger.debug("Registered hook: %s", event.value)

    def register_skill_dir(self, path: Path) -> None:
        """Register a directory containing skill markdown files."""
        if path.exists() and path.is_dir():
            self._skill_dirs.append(path)
            self._logger.debug("Registered skill dir: %s", path)

    # --- Accessors for the plugin loader ---

    def _get_tools(self) -> list[_RegisteredTool]:
        return self._tools

    def _get_hooks(self) -> list[_RegisteredHook]:
        return self._hooks

    def _get_skill_dirs(self) -> list[Path]:
        return self._skill_dirs


class HexisPlugin(ABC):
    """
    Base class for Hexis plugins.

    Subclasses must implement:
    - manifest: Property returning PluginManifest
    - register: Method called with HexisPluginApi to register capabilities
    """

    @property
    @abstractmethod
    def manifest(self) -> PluginManifest:
        """Return the plugin manifest with id, name, version, etc."""
        ...

    @abstractmethod
    def register(self, api: HexisPluginApi) -> None:
        """
        Register tools, hooks, and skills with the plugin API.

        Called once during plugin loading. The plugin should use
        api.register_tool(), api.register_hook(), etc.
        """
        ...
