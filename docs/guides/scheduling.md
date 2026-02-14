<!--
title: Scheduling
summary: Set up cron tasks and active hours for your agent
read_when:
  - "You want to schedule recurring tasks"
  - "You want to configure active hours"
section: guides
-->

# Scheduling

Schedule recurring tasks and configure when your agent is active.

## Quick Start

```bash
# Create a daily task
hexis schedule create morning-briefing \
  --kind daily \
  --action queue_user_message \
  --payload '{"message": "Give me a morning briefing"}' \
  --schedule '{"time": "09:00"}' \
  --timezone "America/New_York"
```

## CLI Commands

```bash
# List scheduled tasks
hexis schedule list
hexis schedule list --status active --json

# Create a task
hexis schedule create <name> \
  --kind {once,interval,daily,weekly} \
  --action {queue_user_message,create_goal} \
  --schedule '<schedule_json>' \
  [--payload '<payload_json>'] \
  [--timezone '<timezone>'] \
  [--description '<description>']

# Delete a task
hexis schedule delete <task_id>
hexis schedule delete <task_id> --force   # hard delete
```

## Schedule Kinds

| Kind | Schedule JSON | Example |
|------|--------------|---------|
| `once` | `{"at": "2026-03-01T09:00:00"}` | One-time execution |
| `interval` | `{"seconds": 3600}` | Every hour |
| `daily` | `{"time": "09:00"}` | Every day at 9 AM |
| `weekly` | `{"day": "monday", "time": "09:00"}` | Every Monday at 9 AM |

## Actions

| Action | Payload | Description |
|--------|---------|-------------|
| `queue_user_message` | `{"message": "..."}` | Sends a message to the agent as if from the user |
| `create_goal` | `{"title": "...", "priority": "active"}` | Creates a new goal |

## Agent-Side Scheduling

The agent can also manage schedules via the `manage_schedule` tool during chat or heartbeats. This allows the agent to create, modify, and delete its own scheduled tasks.

## Active Hours

Configure when the agent should be active (affects heartbeat decisions, especially social actions):

```sql
-- Set active hours (agent won't initiate outreach outside these times)
SELECT set_config('agent.active_hours_start', '"09:00"'::jsonb);
SELECT set_config('agent.active_hours_end', '"22:00"'::jsonb);
SELECT set_config('agent.timezone', '"America/New_York"'::jsonb);
```

## Related

- [Heartbeat](heartbeat.md) -- how scheduled tasks integrate with the heartbeat
- [Goals and Backlog](goals-and-backlog.md) -- goal-driven scheduling
- [CLI reference](../reference/cli.md) -- full `hexis schedule` syntax
