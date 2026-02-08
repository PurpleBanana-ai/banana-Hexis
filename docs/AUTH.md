# Auth Providers

Hexis supports multiple LLM providers via OAuth, device-code, or token-based authentication. All credentials are stored in the Postgres `config` table and refreshed automatically.

## Provider Matrix

| Provider ID | Auth Type | DB Config Key | Runtime Style |
|---|---|---|---|
| `openai-codex` | OAuth PKCE | `oauth.openai_codex` | OpenAI Responses API (Codex) |
| `anthropic` (setup-token) | Paste token | `token.anthropic_setup_token` | Anthropic Messages HTTP (Bearer) |
| `chutes` | OAuth PKCE | `oauth.chutes` | OpenAI-compatible |
| `github-copilot` | Device code | `oauth.github_copilot` | OpenAI-compatible + Copilot headers |
| `qwen-portal` | Device code + PKCE | `oauth.qwen_portal` | OpenAI-compatible |
| `minimax-portal` | User code + PKCE | `oauth.minimax_portal` | Anthropic-compatible HTTP |
| `google-gemini-cli` | OAuth PKCE | `oauth.google_gemini_cli` | Cloud Code Assist SSE |
| `google-antigravity` | OAuth PKCE | `oauth.google_antigravity` | Cloud Code Assist SSE |

All providers can be configured for any LLM slot (`llm.chat`, `llm.heartbeat`, `llm.subconscious`).

---

## OpenAI Codex (ChatGPT Subscription)

Uses your ChatGPT Plus/Pro subscription via OAuth + PKCE. This is **not** OpenAI Platform API-key auth.

### Login

```bash
hexis auth openai-codex login
```

Opens a browser to `auth.openai.com`, captures the callback on `http://localhost:1455/auth/callback`, and stores credentials in `oauth.openai_codex`.

Options:
- `--no-open` — Don't open browser automatically (prints URL instead)
- `--timeout-seconds N` — Callback wait timeout (default: 60)

If the callback can't bind (headless/remote), copy the redirect URL and paste it back.

### Configure

```
llm.chat.provider = "openai-codex"
llm.chat.model = "gpt-5.2"
```

### Status / Logout

```bash
hexis auth openai-codex status [--json]
hexis auth openai-codex logout [--yes]
```

---

## Anthropic (Setup Token)

Uses a Claude Code setup token for Bearer auth against the Anthropic Messages API. No paid API key required if you have a Claude subscription.

### Setup

```bash
hexis auth anthropic setup-token
```

Prompts for a token (prefix `sk-ant-oat01-`, min 80 chars). You can also pass `--token TOKEN` directly.

### Configure

```
llm.chat.provider = "anthropic"
llm.chat.model = "claude-sonnet-4-20250514"
```

When `provider = "anthropic"` and no `ANTHROPIC_API_KEY` env var is set, Hexis automatically falls back to the stored setup token with Bearer auth.

### Status / Logout

```bash
hexis auth anthropic status [--json]
hexis auth anthropic logout [--yes]
```

---

## Chutes

Free LLM inference via Chutes OAuth.

### Login

```bash
hexis auth chutes login
```

Opens a browser to `api.chutes.ai/idp/authorize` using PKCE. Callback on `http://localhost:9876/callback`.

Options:
- `--no-open` — Print URL instead of opening browser
- `--timeout-seconds N` — Wait timeout (default: 120)
- `--manual` — Paste redirect URL manually
- `--client-id ID` — Override client ID

### Configure

```
llm.chat.provider = "chutes"
llm.chat.model = "deepseek-ai/DeepSeek-V3-0324"
```

Default endpoint: `https://api.chutes.ai/v1`

### Status / Logout

```bash
hexis auth chutes status [--json]
hexis auth chutes logout [--yes]
```

---

## GitHub Copilot

Uses GitHub Copilot via device code auth.

### Login

```bash
hexis auth github-copilot login
```

Starts a device code flow — prints a user code and opens `github.com/login/device`. After authorization, exchanges for a Copilot API token.

Options:
- `--enterprise-domain DOMAIN` — GitHub Enterprise domain (default: `github.com`)
- `--timeout-seconds N` — Polling timeout (default: 120)

### Configure

```
llm.chat.provider = "github-copilot"
llm.chat.model = "gpt-4o"
```

Endpoint is derived automatically from the Copilot token.

### Status / Logout

```bash
hexis auth github-copilot status [--json]
hexis auth github-copilot logout [--yes]
```

---

## Qwen Portal

Free access to Qwen models via device code auth.

### Login

```bash
hexis auth qwen-portal login
```

Starts a device code flow — prints a URL and user code to enter in the browser. Polls until authorized.

Options:
- `--timeout-seconds N` — Polling timeout (default: 120)

### Configure

```
llm.chat.provider = "qwen-portal"
llm.chat.model = "qwen-max-latest"
```

Default endpoint: `https://portal.qwen.ai/v1`

### Status / Logout

```bash
hexis auth qwen-portal status [--json]
hexis auth qwen-portal logout [--yes]
```

---

## MiniMax Portal

Access MiniMax models via user-code + PKCE auth.

### Login

```bash
hexis auth minimax-portal login
```

Starts a user-code flow — prints a code and URL. After entering the code in the browser, exchanges for an API token.

Options:
- `--region global|cn` — API region (default: `global`)
- `--timeout-seconds N` — Polling timeout (default: 120)

### Configure

```
llm.chat.provider = "minimax-portal"
llm.chat.model = "MiniMax-M1"
```

Default endpoints:
- Global: `https://api.minimax.io/anthropic`
- CN: `https://api.minimaxi.com/anthropic`

### Status / Logout

```bash
hexis auth minimax-portal status [--json]
hexis auth minimax-portal logout [--yes]
```

---

## Google Gemini CLI

Uses Google Cloud Code Assist via OAuth PKCE (same auth as `gemini` CLI).

### Prerequisites

Set environment variables:
```bash
export GEMINI_CLI_OAUTH_CLIENT_ID="..."
export GEMINI_CLI_OAUTH_CLIENT_SECRET="..."
```

These can be extracted from an installed `gemini` CLI or obtained from Google Cloud Console.

### Login

```bash
hexis auth google-gemini-cli login
```

Opens a browser to `accounts.google.com` for OAuth. Callback on `http://localhost:8085/oauth2callback`. After auth, discovers your Cloud Code Assist project.

Options:
- `--no-open` — Print URL instead of opening browser
- `--timeout-seconds N` — Wait timeout (default: 120)
- `--manual` — Paste redirect URL manually

### Configure

```
llm.chat.provider = "google-gemini-cli"
llm.chat.model = "gemini-2.5-flash"
```

Default endpoint: `https://cloudcode-pa.googleapis.com`

### Status / Logout

```bash
hexis auth google-gemini-cli status [--json]
hexis auth google-gemini-cli logout [--yes]
```

---

## Google Antigravity

Uses Google Cloud Code Assist sandbox via OAuth PKCE (different constants from Gemini CLI).

### Prerequisites

Set environment variables:
```bash
export ANTIGRAVITY_OAUTH_CLIENT_ID="..."
export ANTIGRAVITY_OAUTH_CLIENT_SECRET="..."
```

### Login

```bash
hexis auth google-antigravity login
```

Opens a browser to `accounts.google.com` for OAuth. Callback on `http://localhost:51121/oauth-callback`.

Options:
- `--no-open` — Print URL instead of opening browser
- `--timeout-seconds N` — Wait timeout (default: 120)
- `--manual` — Paste redirect URL manually

### Configure

```
llm.chat.provider = "google-antigravity"
llm.chat.model = "gemini-2.5-flash"
```

Default endpoint: `https://cloudcode-pa.googleapis.com` (with sandbox fallback)

### Status / Logout

```bash
hexis auth google-antigravity status [--json]
hexis auth google-antigravity logout [--yes]
```

---

## Troubleshooting

### "Provider X is not configured"

Run `hexis auth <provider> login` (or `setup-token` for Anthropic) to store credentials.

### "Credentials expired and no refresh token"

Re-run `hexis auth <provider> login` to get a fresh token.

### Callback server won't bind

Use `--manual` (for PKCE providers) to paste the redirect URL manually. Or use `--no-open` and copy the URL to a different browser.

### `hexis doctor` shows auth warnings

Run `hexis auth <provider> status` to check credential health. The doctor validates that stored credentials have an `access` field for OAuth providers.

### Environment variable API keys

For `openai`, `anthropic`, `grok`, and `gemini` providers, you can still use traditional API keys via environment variables (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.) instead of OAuth. The auth commands are only needed for OAuth/token-based providers.
