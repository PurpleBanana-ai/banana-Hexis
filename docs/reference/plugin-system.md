<!--
title: Plugin System
summary: Plugin ABC, manifest, and hook events for extending Hexis
read_when:
  - "You want to extend Hexis with a plugin"
  - "You want to understand the plugin architecture"
section: reference
-->

# Plugin System

Extend Hexis with custom tools, hooks, and skills via the plugin system.

## Overview

Plugins are Python packages that implement the `HexisPlugin` ABC. They are:

- Discovered from `plugins/installed/` directory
- Loaded at startup via `load_plugins(pool)`
- Registered via the `HexisPluginApi` injection object

## Plugin Structure

```
plugins/installed/my_plugin/
├── __init__.py          # exports HexisPlugin subclass
├── tools.py             # custom ToolHandler implementations
└── skills/
    └── my-skill/
        └── SKILL.md     # skill definition
```

## Core Classes

### PluginManifest

```python
@dataclass
class PluginManifest:
    id: str                        # Unique identifier
    name: str                      # Display name
    version: str = "0.0.0"        # Semantic version
    description: str = ""         # Purpose
    config_schema: dict = field(default_factory=dict)  # JSON schema
```

### HexisPlugin (ABC)

```python
class HexisPlugin(ABC):
    @property
    def manifest(self) -> PluginManifest:
        """Return plugin metadata"""

    def register(self, api: HexisPluginApi) -> None:
        """Called once during loading; register capabilities"""
```

### HexisPluginApi

The injection object provided to plugins during registration:

```python
class HexisPluginApi:
    @property
    def plugin_id(self) -> str           # Plugin ID
    @property
    def pool(self) -> asyncpg.Pool       # DB connection pool
    @property
    def config(self) -> dict             # Plugin config from DB
    @property
    def logger(self) -> logging.Logger   # Namespaced logger

    def register_tool(handler: ToolHandler, *, optional: bool = False) -> None
    def register_hook(event: HookEvent, handler: HookHandler) -> None
    def register_skill_dir(path: Path) -> None
```

## Registration Methods

### register_tool

Add a custom tool to the registry:

```python
api.register_tool(MyToolHandler())           # always available
api.register_tool(MyToolHandler(), optional=True)  # requires explicit enable
```

If a plugin tool name conflicts with core tools, the plugin tool is skipped with a warning.

### register_hook

Listen for execution events:

```python
api.register_hook(HookEvent.BEFORE_TOOL_CALL, MyHook())
api.register_hook(HookEvent.AFTER_TOOL_CALL, MyHook())
```

| Event | Description |
|-------|-------------|
| `BEFORE_TOOL_CALL` | Can block or mutate arguments |
| `AFTER_TOOL_CALL` | Observe/log execution results |

### register_skill_dir

Add a directory of skills:

```python
api.register_skill_dir(Path(__file__).parent / "skills")
```

## Example Plugin

```python
from plugins.base import HexisPlugin, PluginManifest, HexisPluginApi, HookEvent

class MyPlugin(HexisPlugin):
    @property
    def manifest(self) -> PluginManifest:
        return PluginManifest(
            id="my_plugin",
            name="My Plugin",
            version="1.0.0",
            description="Adds custom weather tool",
        )

    def register(self, api: HexisPluginApi) -> None:
        api.register_tool(WeatherToolHandler())
        api.register_hook(HookEvent.AFTER_TOOL_CALL, LoggingHook())
        api.register_skill_dir(Path(__file__).parent / "skills")
```

## Plugin Configuration

Plugin config is stored in the `config` table under `plugin.<plugin_id>` and validated against the manifest's `config_schema`.

## Related

- [Tools Reference](tools.md) -- tool handler pattern
- [Skills](../guides/skills.md) -- skill format and management
