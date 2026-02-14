<!--
title: Slack
summary: Slack bot integration for Hexis
read_when:
  - "You want to connect your agent to Slack"
section: integrations
-->

# Slack

Connect your Hexis agent to Slack workspaces.

> **Status**: Production-ready
> **Adapter**: `channels/slack_adapter.py`
> **Library**: `slack-bolt` + `slack-sdk`
> **Connection**: Socket Mode (primary) or HTTP Events (fallback)

## Prerequisites

- A Slack app with Bot token (`xoxb-...`) from the [Slack API](https://api.slack.com/apps)
- App token (`xapp-...`) for Socket Mode (recommended)
- Required scopes: `chat:write`, `channels:history`, `im:history`

## Quick Start

```bash
hexis channels setup slack
hexis up --profile active
hexis channels status
```

## Configuration

| Config Key | Type | Description |
|------------|------|-------------|
| `channel.slack.bot_token` | text | Env var name for `xoxb-...` bot token |
| `channel.slack.app_token` | text | Env var name for `xapp-...` app token (Socket Mode) |
| `channel.slack.allowed_channels` | array | JSON array of channel IDs or `"*"` (all) |

Environment variables: `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`

## Connection Modes

| Mode | Requires | Notes |
|------|----------|-------|
| **Socket Mode** (recommended) | Bot token + App token | Bidirectional, works behind firewalls, no webhook setup |
| **HTTP Events** (fallback) | Bot token + webhook URL | Requires external accessibility; used if `app_token` is missing |

Socket Mode is strongly recommended -- it works behind NAT and firewalls without any webhook configuration.

## Features

| Feature | Supported | Notes |
|---------|-----------|-------|
| Direct messages | Yes | Always responds |
| Channel messages | Yes | Responds to bot mentions |
| Threads | Yes | Extracts `thread_ts` as thread_id |
| Reactions | Yes | Emoji reactions |
| Media (files, images) | Yes | Uses `files_upload_v2()` |
| Typing indicator | No | Slack API does not support bot typing indicators (silently skipped) |
| Edit messages | Yes | Via message timestamp |
| Max message length | 4,000 chars | |

## How It Works

- Uses `slack-bolt` `AsyncApp` with event-driven architecture
- Listens on `@app.event("message")` for incoming messages
- Ignores bot messages (`bot_id` present) and message subtypes (edits, joins, leaves)
- **User info**: Fetches display name asynchronously via `client.users_info(user=user_id)`
- **Thread support**: Uses Slack's `thread_ts` (timestamp) for threaded conversations
- **Channel filtering**: Responds to allowlisted channels; always responds when mentioned in non-allowed channels
- **File attachments**: Extracts `url_private_download` or `url_private` from file metadata

## Troubleshooting

- **Bot not responding**: Verify both `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN` are set
- **Socket Mode errors**: Ensure Socket Mode is enabled in your Slack app settings (Settings > Socket Mode)
- **Missing permissions**: Add `chat:write`, `channels:history`, `im:history` scopes to your bot token
- **No typing indicator**: This is expected -- the Slack bot API does not support typing indicators
- **HTTP fallback warning**: If you see "Using HTTP fallback" in logs, set the `SLACK_APP_TOKEN` to enable Socket Mode

## Related

- [Channels overview](index.md)
- [Channels Setup guide](../../guides/channels-setup.md)
