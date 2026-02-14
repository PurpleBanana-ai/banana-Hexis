<!--
title: Contributing
summary: Development setup, coding style, and contribution guidelines
read_when:
  - "You want to contribute to Hexis"
  - "You need to set up a development environment"
section: contributing
-->

# Contributing

## Development Setup

```bash
git clone https://github.com/QuixiAI/Hexis.git && cd Hexis
pip install -e .
cp .env.local .env   # edit with your API keys
hexis up             # start services
hexis doctor         # verify health
```

## Coding Style

- **Python**: Follow Black formatting; prefer type hints and explicit names
- **Database authority**: Add/modify SQL in `db/*.sql` rather than duplicating logic in Python
- **Additive schema changes**: Prefer backwards-compatible changes; avoid renames unless necessary
- **Stateless workers**: Workers can be killed/restarted without losing state; all state lives in Postgres

## Project Structure

```
hexis/
├── db/*.sql          # Schema files (tables, functions, triggers, views)
├── core/             # Thin DB + LLM adapter
│   └── tools/        # ~80 tool handlers across 11 categories
├── services/         # Orchestration (conversation, ingestion, workers)
├── apps/             # CLI, API server, MCP server, workers
├── channels/         # Messaging adapters
├── characters/       # Preset character cards
├── skills/           # Declarative workflow packages
├── plugins/          # Plugin system
├── tests/            # pytest test suite
└── docs/             # Documentation
```

## Commit Guidelines

- Short, imperative summaries (e.g., "Add MCP server tools", "Gate heartbeat on config")
- Include rationale, how to run/verify, and any DB reset requirements in PR descriptions
- Call out changes to `db/*.sql`, `docker-compose.yml`, `README.md`

## Testing

See [Testing](testing.md) for test conventions, running tests, and writing new tests.

## Key Principles

1. **Database is the brain** -- state and logic live in Postgres
2. **Schema authority** -- `db/*.sql` is the source of truth
3. **Stateless workers** -- can be killed/restarted without losing anything
4. **ACID for cognition** -- atomic memory updates ensure consistent state
