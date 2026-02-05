"""
Hexis Plugin System - Loader

Discovery and loading of plugins from the filesystem.

Plugins are discovered from:
1. plugins/installed/ directory (bundled)
2. Additional directories from DB config (plugin.external_dirs)
"""

from __future__ import annotations

import importlib
import json
import logging
import sys
from pathlib import Path
from typing import Any, TYPE_CHECKING

from .base import HexisPlugin, HexisPluginApi, PluginManifest, _RegisteredHook, _RegisteredTool
from .registry import PluginRegistry, _PluginToolEntry, _PluginHookEntry

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger(__name__)

# Default plugin directory (bundled with repo)
_PLUGINS_DIR = Path(__file__).resolve().parent / "installed"


def discover_plugins(extra_dirs: list[Path] | None = None) -> list[Path]:
    """
    Discover plugin directories.

    Each plugin is a subdirectory containing either:
    - plugin.json (manifest) + __init__.py (entry point)
    - Just __init__.py with a class implementing HexisPlugin

    Returns list of plugin directory paths.
    """
    dirs_to_scan = [_PLUGINS_DIR]
    if extra_dirs:
        dirs_to_scan.extend(extra_dirs)

    plugins: list[Path] = []
    for base_dir in dirs_to_scan:
        if not base_dir.exists():
            continue
        for child in sorted(base_dir.iterdir()):
            if not child.is_dir():
                continue
            if child.name.startswith((".", "_")):
                continue
            # Must have __init__.py
            if (child / "__init__.py").exists():
                plugins.append(child)

    return plugins


def _load_plugin_module(plugin_dir: Path) -> HexisPlugin | None:
    """Import a plugin package and find the HexisPlugin subclass."""
    module_name = f"_hexis_plugin_{plugin_dir.name}"

    # Add parent to sys.path temporarily if needed
    parent = str(plugin_dir.parent)
    added_to_path = False
    if parent not in sys.path:
        sys.path.insert(0, parent)
        added_to_path = True

    try:
        # Import the package
        spec = importlib.util.spec_from_file_location(
            module_name,
            plugin_dir / "__init__.py",
            submodule_search_locations=[str(plugin_dir)],
        )
        if spec is None or spec.loader is None:
            logger.warning("Could not create module spec for plugin: %s", plugin_dir)
            return None

        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)

        # Look for a HexisPlugin subclass or a 'plugin' attribute
        if hasattr(module, "plugin") and isinstance(module.plugin, HexisPlugin):
            return module.plugin

        # Search for HexisPlugin subclass instances
        for attr_name in dir(module):
            attr = getattr(module, attr_name)
            if isinstance(attr, HexisPlugin):
                return attr

        # Search for HexisPlugin subclass (not instance)
        for attr_name in dir(module):
            attr = getattr(module, attr_name)
            if (
                isinstance(attr, type)
                and issubclass(attr, HexisPlugin)
                and attr is not HexisPlugin
            ):
                return attr()

        logger.warning("No HexisPlugin found in plugin: %s", plugin_dir)
        return None

    except Exception:
        logger.exception("Failed to load plugin: %s", plugin_dir)
        return None
    finally:
        if added_to_path and parent in sys.path:
            sys.path.remove(parent)


async def _load_plugin_config(pool: "asyncpg.Pool", plugin_id: str) -> dict[str, Any]:
    """Load plugin-specific config from the database."""
    try:
        async with pool.acquire() as conn:
            raw = await conn.fetchval(
                "SELECT value FROM config WHERE key = $1",
                f"plugin.{plugin_id}",
            )
            if raw is None:
                return {}
            if isinstance(raw, str):
                return json.loads(raw)
            if isinstance(raw, dict):
                return raw
            return {}
    except Exception:
        logger.debug("No config found for plugin %s", plugin_id)
        return {}


async def load_plugins(
    pool: "asyncpg.Pool",
    extra_dirs: list[Path] | None = None,
) -> PluginRegistry:
    """
    Discover and load all plugins.

    Args:
        pool: Database connection pool
        extra_dirs: Additional directories to scan for plugins

    Returns:
        PluginRegistry with all registered capabilities
    """
    registry = PluginRegistry()
    plugin_dirs = discover_plugins(extra_dirs)

    if not plugin_dirs:
        logger.debug("No plugins discovered")
        return registry

    seen_ids: set[str] = set()

    for plugin_dir in plugin_dirs:
        # Load the plugin module
        plugin_obj = _load_plugin_module(plugin_dir)
        if plugin_obj is None:
            continue

        manifest = plugin_obj.manifest

        # Check for ID conflicts
        if manifest.id in seen_ids:
            logger.error("Duplicate plugin ID: %s (skipping %s)", manifest.id, plugin_dir)
            continue
        seen_ids.add(manifest.id)

        # Load plugin config from DB
        plugin_config = await _load_plugin_config(pool, manifest.id)

        # Create API object
        api = HexisPluginApi(
            plugin_id=manifest.id,
            pool=pool,
            plugin_config=plugin_config,
        )

        # Run registration
        try:
            plugin_obj.register(api)
        except Exception:
            logger.exception("Plugin registration failed: %s", manifest.id)
            continue

        # Collect registrations
        tools = [
            _PluginToolEntry(
                plugin_id=manifest.id,
                handler=rt.handler,
                optional=rt.optional,
            )
            for rt in api._get_tools()
        ]
        hooks = [
            _PluginHookEntry(
                plugin_id=manifest.id,
                event=rh.event,
                handler=rh.handler,
            )
            for rh in api._get_hooks()
        ]
        skill_dirs = api._get_skill_dirs()

        registry._add_plugin(
            plugin_id=manifest.id,
            manifest_dict=manifest.to_dict(),
            tools=tools,
            hooks=hooks,
            skill_dirs=skill_dirs,
        )

        logger.info(
            "Loaded plugin: %s v%s (%d tools, %d hooks, %d skill dirs)",
            manifest.id, manifest.version,
            len(tools), len(hooks), len(skill_dirs),
        )

    logger.info(
        "Plugin loading complete: %d plugins, %d tools, %d hooks",
        registry.plugin_count(), registry.tool_count(), registry.hook_count(),
    )
    return registry
