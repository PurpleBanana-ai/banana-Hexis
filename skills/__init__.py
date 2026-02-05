"""
Hexis Skills System

Skills are markdown documents with YAML frontmatter that provide context
to the LLM without being callable tools. They teach the agent about
available capabilities, methodologies, and best practices.

Skills differ from tools:
- Tools = LLM-callable functions (JSON schema)
- Skills = Prompt context documents (markdown injected into system prompt)

Skills differ from memories:
- Memories = experiential knowledge with trust, decay, embeddings
- Skills = static documentation, always present when requirements met

Example usage:

    from skills import load_skills, SkillContext

    # Load skills matching current context
    active_skills = load_skills(
        context=SkillContext.HEARTBEAT,
        available_tools={"recall", "web_search", "web_fetch"},
        available_config={"tavily"},
    )

    # Inject into system prompt
    for skill in active_skills:
        system_prompt += f"\\n\\n{skill.to_prompt_block()}"
"""

from .base import SkillContext, SkillSpec
from .loader import load_skills, load_skills_from_dir, discover_skill_dirs

__all__ = [
    "SkillContext",
    "SkillSpec",
    "load_skills",
    "load_skills_from_dir",
    "discover_skill_dirs",
]
