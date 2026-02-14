<!--
title: First Conversation
summary: Start chatting with your Hexis agent
read_when:
  - "You want to talk to your agent"
  - "You want to understand how chat works"
section: start
-->

# First Conversation

Chat with your configured agent using the interactive CLI.

## Quick Start

```bash
hexis chat
```

This opens an interactive conversation loop with memory enrichment and tool access.

## How It Works

The chat loop automatically:

1. **Enriches your prompt** with relevant memories from the agent's brain (RAG-style)
2. **Gives the agent tools** via function calling -- memory operations, web search, file access, and more
3. **Forms new memories** from the conversation (the agent remembers what you discuss)

## Chat Options

```bash
# Default: memory tools + extended tools (web, filesystem, shell)
hexis chat

# Specify a different LLM endpoint
hexis chat --endpoint http://localhost:11434/v1 --model llama3.2

# Memory tools only (no web/filesystem/shell)
hexis chat --no-extended-tools

# Quiet mode (less verbose output)
hexis chat -q
```

## What to Try

- **Ask about itself** -- "What do you know about yourself?" (tests identity retrieval)
- **Tell it something** -- "I prefer dark mode" (tests memory formation)
- **Ask a follow-up** -- "What do I prefer?" (tests memory recall)
- **Give it a goal** -- "I want you to help me learn Python" (tests goal creation)

## Understanding the Output

During chat, you may see:

- **Memory recall indicators** -- shows which memories were retrieved for context
- **Tool calls** -- shows when the agent uses tools (recall, remember, web_search, etc.)
- **Memory formation** -- indicates new memories being created from the conversation

## Verify Memories Were Created

After chatting, check that the agent remembered:

```bash
hexis recall "what we discussed"    # search memories
hexis status                         # see memory counts
```

## Next Steps

- [Next Steps](next-steps.md) -- explore more features
