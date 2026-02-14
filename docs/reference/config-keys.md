<!--
title: Config Keys
summary: All config table keys with types and defaults
read_when:
  - "You need to check or set a config value"
  - "You want to see all configuration options"
section: reference
-->

# Config Keys

All keys stored in the Postgres `config` table. Values are JSONB.

## Querying Config

```sql
-- Get a specific key
SELECT value FROM config WHERE key = 'llm.chat';

-- Using helper functions
SELECT get_config_text('llm.chat.provider');
SELECT get_config_int('heartbeat.interval_seconds');
SELECT get_config_bool('agent.is_configured');

-- Set a value
SELECT set_config('agent.name', '"MyAgent"'::jsonb);
```

## Agent Configuration

| Key | Type | Description |
|-----|------|-------------|
| `agent.is_configured` | bool | Whether init has completed |
| `agent.name` | text | Agent's name |
| `agent.user_name` | text | What to call the user |
| `agent.active_hours_start` | text | Active hours start (e.g., "09:00") |
| `agent.active_hours_end` | text | Active hours end (e.g., "22:00") |
| `agent.timezone` | text | Agent timezone |

## LLM Configuration

| Key | Type | Description |
|-----|------|-------------|
| `llm.chat.provider` | text | Conscious LLM provider |
| `llm.chat.model` | text | Conscious LLM model |
| `llm.chat.endpoint` | text | API endpoint URL |
| `llm.heartbeat.provider` | text | Heartbeat LLM provider (falls back to chat) |
| `llm.heartbeat.model` | text | Heartbeat model |
| `llm.subconscious.provider` | text | Subconscious LLM provider |
| `llm.subconscious.model` | text | Subconscious model |

## Heartbeat Configuration

| Key | Type | Description |
|-----|------|-------------|
| `heartbeat.interval_seconds` | int | Seconds between heartbeats |
| `heartbeat.max_energy` | float | Maximum energy cap |
| `heartbeat.energy_regen_rate` | float | Energy per hour |

## Maintenance Configuration

| Key | Type | Description |
|-----|------|-------------|
| `maintenance.subconscious_enabled` | bool | Toggle subconscious decider |
| `maintenance.subconscious_interval_seconds` | int | Decider cadence |

## Tools Configuration

| Key | Type | Description |
|-----|------|-------------|
| `tools` | object | Tool config: enabled/disabled, API keys, costs, MCP servers |
| `tools.workspace_path` | text | Filesystem tools workspace restriction |

## OAuth Credentials

| Key | Type | Description |
|-----|------|-------------|
| `oauth.openai_codex` | object | OpenAI Codex OAuth credentials |
| `oauth.chutes` | object | Chutes OAuth credentials |
| `oauth.github_copilot` | object | GitHub Copilot credentials |
| `oauth.qwen_portal` | object | Qwen Portal credentials |
| `oauth.minimax_portal` | object | MiniMax Portal credentials |
| `oauth.google_gemini_cli` | object | Google Gemini CLI credentials |
| `oauth.google_antigravity` | object | Google Antigravity credentials |
| `token.anthropic_setup_token` | object | Anthropic setup token |

## Channel Configuration

| Key | Type | Description |
|-----|------|-------------|
| `channel.<name>.bot_token` | text | Env var name for bot token |
| `channel.<name>.allowed_*` | array | Allowlist (guild IDs, chat IDs, etc.) |

## Embedding Configuration

Embedding config is primarily via environment variables, not the config table. See [Environment Variables](../operations/environment-variables.md).

## Related

- [Environment Variables](../operations/environment-variables.md) -- .env configuration
- [Database](../operations/database.md) -- accessing the config table
