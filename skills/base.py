"""
Hexis Skills System - Base Types

SkillSpec: the parsed representation of a skill markdown file.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class SkillContext(str, Enum):
    """Contexts in which a skill can be active."""

    HEARTBEAT = "heartbeat"
    CHAT = "chat"
    MCP = "mcp"


@dataclass
class SkillSpec:
    """Parsed representation of a skill document."""

    name: str
    description: str
    content: str  # Markdown body (after frontmatter)
    requires_tools: list[str] = field(default_factory=list)
    requires_config: list[str] = field(default_factory=list)
    contexts: list[SkillContext] = field(
        default_factory=lambda: [SkillContext.HEARTBEAT, SkillContext.CHAT]
    )
    source: str = ""  # File path or plugin ID that provided this skill

    def requirements_met(
        self,
        available_tools: set[str],
        available_config: set[str] | None = None,
    ) -> bool:
        """Check if all requirements are satisfied."""
        for tool in self.requires_tools:
            if tool not in available_tools:
                return False
        if available_config is not None:
            for key in self.requires_config:
                if key not in available_config:
                    return False
        return True

    def to_prompt_block(self) -> str:
        """Format this skill for injection into a system prompt."""
        return f"<skill name=\"{self.name}\">\n{self.content}\n</skill>"

    @classmethod
    def from_frontmatter(cls, metadata: dict[str, Any], content: str, source: str = "") -> "SkillSpec":
        """Create a SkillSpec from parsed YAML frontmatter and markdown body."""
        # Parse contexts
        raw_contexts = metadata.get("contexts", ["heartbeat", "chat"])
        if isinstance(raw_contexts, str):
            raw_contexts = [raw_contexts]
        contexts = []
        for ctx in raw_contexts:
            try:
                contexts.append(SkillContext(ctx))
            except ValueError:
                pass
        if not contexts:
            contexts = [SkillContext.HEARTBEAT, SkillContext.CHAT]

        # Parse requires
        requires = metadata.get("requires", {})
        if not isinstance(requires, dict):
            requires = {}

        return cls(
            name=str(metadata.get("name", "")),
            description=str(metadata.get("description", "")),
            content=content.strip(),
            requires_tools=list(requires.get("tools", [])),
            requires_config=list(requires.get("config", [])),
            contexts=contexts,
            source=source,
        )
