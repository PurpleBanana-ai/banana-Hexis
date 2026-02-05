"""
Hexis Skills System - Loader

Discovery and loading of skill markdown files from directories.
Skills use YAML frontmatter for metadata and markdown for content.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Any

from .base import SkillContext, SkillSpec

logger = logging.getLogger(__name__)

# Default skills directory (bundled with repo)
_SKILLS_DIR = Path(__file__).resolve().parent / "installed"

# YAML frontmatter regex: --- at start, content, --- delimiter
_FRONTMATTER_RE = re.compile(
    r"\A---\s*\n(.*?)\n---\s*\n(.*)",
    re.DOTALL,
)


def _parse_yaml_simple(text: str) -> dict[str, Any]:
    """
    Minimal YAML-like parser for skill frontmatter.

    Handles flat key: value pairs, lists (- item), and nested dicts.
    Avoids a PyYAML dependency for this simple use case.
    Falls back to PyYAML if available.
    """
    try:
        import yaml
        return yaml.safe_load(text) or {}
    except ImportError:
        pass

    result: dict[str, Any] = {}
    current_key = ""
    current_list: list[str] | None = None
    current_dict: dict[str, Any] | None = None

    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        # List item
        if stripped.startswith("- ") and current_key:
            item = stripped[2:].strip().strip("'\"")
            if current_list is not None:
                current_list.append(item)
            continue

        # Nested key (indented)
        indent = len(line) - len(line.lstrip())
        if indent > 0 and ":" in stripped and current_dict is not None:
            k, _, v = stripped.partition(":")
            v = v.strip().strip("'\"")
            if v.startswith("[") and v.endswith("]"):
                v = [x.strip().strip("'\"") for x in v[1:-1].split(",") if x.strip()]
            current_dict[k.strip()] = v
            continue

        # Top-level key: value
        if ":" in stripped and indent == 0:
            # Save previous list/dict (prefer dict if populated)
            if current_key:
                if current_dict:
                    result[current_key] = current_dict
                elif current_list:
                    result[current_key] = current_list
                elif current_list is not None:
                    result[current_key] = current_list  # genuinely empty list
            current_list = None
            current_dict = None

            k, _, v = stripped.partition(":")
            current_key = k.strip()
            v = v.strip()

            if not v:
                # Could be a list or dict following
                current_list = []
                current_dict = {}
            elif v.startswith("[") and v.endswith("]"):
                result[current_key] = [
                    x.strip().strip("'\"") for x in v[1:-1].split(",") if x.strip()
                ]
                current_key = ""
            else:
                result[current_key] = v.strip("'\"")
                current_key = ""

    # Save trailing list/dict
    if current_list is not None and current_key:
        result[current_key] = current_list if current_list else (current_dict or {})
    elif current_dict is not None and current_key:
        result[current_key] = current_dict

    return result


def _parse_skill_file(path: Path) -> SkillSpec | None:
    """Parse a single skill markdown file."""
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as exc:
        logger.warning("Failed to read skill file %s: %s", path, exc)
        return None

    match = _FRONTMATTER_RE.match(text)
    if not match:
        logger.warning("Skill file %s has no YAML frontmatter, skipping", path)
        return None

    frontmatter_text = match.group(1)
    body = match.group(2)

    metadata = _parse_yaml_simple(frontmatter_text)
    if not metadata.get("name"):
        # Use filename as fallback
        metadata["name"] = path.stem

    return SkillSpec.from_frontmatter(metadata, body, source=str(path))


def load_skills_from_dir(directory: Path) -> list[SkillSpec]:
    """Load all skills from a directory (including subdirectories)."""
    skills: list[SkillSpec] = []

    if not directory.exists():
        return skills

    # Look for SKILL.md files in subdirectories
    for skill_file in sorted(directory.rglob("SKILL.md")):
        spec = _parse_skill_file(skill_file)
        if spec:
            skills.append(spec)

    # Also look for top-level .md files
    for skill_file in sorted(directory.glob("*.md")):
        if skill_file.name == "SKILL.md":
            continue  # Already handled above
        spec = _parse_skill_file(skill_file)
        if spec:
            skills.append(spec)

    return skills


def discover_skill_dirs() -> list[Path]:
    """Discover all skill directories to scan."""
    dirs: list[Path] = []

    # Bundled skills
    if _SKILLS_DIR.exists():
        dirs.append(_SKILLS_DIR)

    return dirs


def load_skills(
    context: SkillContext,
    available_tools: set[str],
    available_config: set[str] | None = None,
    extra_dirs: list[Path] | None = None,
) -> list[SkillSpec]:
    """
    Load all skills matching a context whose requirements are met.

    Args:
        context: The execution context (heartbeat, chat, mcp)
        available_tools: Set of tool names currently enabled
        available_config: Set of config keys present (e.g., api key names)
        extra_dirs: Additional directories to scan for skills

    Returns:
        List of SkillSpec objects ready for prompt injection
    """
    dirs = discover_skill_dirs()
    if extra_dirs:
        dirs.extend(extra_dirs)

    all_skills: list[SkillSpec] = []
    seen_names: set[str] = set()

    for d in dirs:
        for spec in load_skills_from_dir(d):
            if spec.name in seen_names:
                logger.debug("Skipping duplicate skill: %s", spec.name)
                continue

            # Check context match
            if context not in spec.contexts:
                continue

            # Check requirements
            if not spec.requirements_met(available_tools, available_config):
                logger.debug(
                    "Skill '%s' requirements not met (tools=%s config=%s)",
                    spec.name, spec.requires_tools, spec.requires_config,
                )
                continue

            all_skills.append(spec)
            seen_names.add(spec.name)

    logger.debug("Loaded %d skills for context=%s", len(all_skills), context.value)
    return all_skills
