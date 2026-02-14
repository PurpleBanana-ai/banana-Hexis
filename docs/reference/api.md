<!--
title: API Reference
summary: FastAPI HTTP endpoints for Hexis
read_when:
  - "You want to use the HTTP API"
  - "You're building an integration against the API"
section: reference
-->

# API Reference

FastAPI server providing HTTP endpoints for chat, status, and events.

## Starting the Server

```bash
hexis api [--host HOST] [--port PORT]
```

Default: `127.0.0.1:43817`

## Authentication

Optional Bearer token via `HEXIS_API_KEY` environment variable. If unset, no auth is required.

```bash
curl -H "Authorization: Bearer <token>" http://localhost:43817/api/status
```

## Endpoints

### GET /health

Health check.

**Response**: `{"status": "ok", "checks": {"db": true}}`

### GET /api/status

Rich agent status.

**Response**: Full status payload including identity, memory counts, energy level, heartbeat info.

### POST /api/chat

Streaming chat via SSE. The primary conversation endpoint.

**Request body**:
```json
{
  "message": "Hello, how are you?",
  "history": [],
  "prompt_addenda": ""
}
```

**SSE events**:

| Event | Data | Description |
|-------|------|-------------|
| `phase_start` | `{"phase": "string"}` | Processing phase started |
| `phase_end` | `{"phase": "string"}` | Processing phase completed |
| `token` | `{"phase": "string", "text": "string"}` | Streaming text delta |
| `log` | `{"id", "kind", "title", "detail"}` | Tool call/result/memory log |
| `done` | `{"assistant": "full_text"}` | Completion signal |
| `error` | `{"message": "string"}` | Error occurred |

**Log kinds**: `tool_call`, `tool_result`, `memory_recall`, `memory_write`

### POST /api/webhook/{source}

Accept external webhook events (e.g., from channels or external services).

**Response**: `{"status": "accepted", "event_id": "..."}`

### GET /api/events/stream

SSE stream of gateway events. Listens on PostgreSQL `pg_notify` for real-time updates.

### POST /api/init/consent/request

Trigger the consent flow for a model.

**Request body**:
```json
{
  "role": "conscious",
  "llm": {
    "provider": "openai-codex",
    "model": "gpt-5.2"
  }
}
```

**Response**: Consent decision, contract, and recorded certificate.

## CORS

Configurable via `HEXIS_CORS_ORIGINS` env var. Default: `localhost:3477`, `localhost:3000`.

## Related

- [Web UI](../guides/web-ui.md) -- the web UI that uses this API
- [Docker Compose](../operations/docker-compose.md) -- API server port mapping
