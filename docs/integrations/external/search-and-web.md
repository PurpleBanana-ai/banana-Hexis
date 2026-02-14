<!--
title: Search and Web
summary: Brave Search, Firecrawl, and web tool integrations
read_when:
  - "You want to enable web search"
  - "You want to scrape web pages"
section: integrations
-->

# Search and Web

Enable web search, content fetching, and page scraping capabilities.

## Built-in Web Tools

These tools are available without external API keys:

| Tool | Energy | Description |
|------|--------|-------------|
| `web_search` | 2 | Search the web (uses configured search provider) |
| `web_fetch` | 2 | Fetch and extract content from a URL |
| `web_summarize` | 4 | Fetch a URL and generate a summary |

## Brave Search

### Setup

```bash
hexis tools set-api-key brave env:BRAVE_API_KEY
hexis tools enable brave_search
```

| Tool | Energy | Description |
|------|--------|-------------|
| `brave_search` | 2 | Search via Brave Search API |

Get your API key from [Brave Search API](https://brave.com/search/api/).

## Firecrawl

### Setup

```bash
hexis tools set-api-key firecrawl env:FIRECRAWL_API_KEY
hexis tools enable firecrawl_scrape
```

| Tool | Energy | Description |
|------|--------|-------------|
| `firecrawl_scrape` | 3 | Scrape and extract structured content from web pages |

Get your API key from [Firecrawl](https://firecrawl.dev/).

## Browser Automation

For interactive web automation (filling forms, clicking buttons, navigating):

| Tool | Energy | Description |
|------|--------|-------------|
| `browser` | 4 | Headless browser automation via Playwright/CDP |

Requires the `browser` Docker Compose profile:

```bash
docker compose --profile active --profile browser up -d
```

## Related

- [Tools Configuration](../../guides/tools-configuration.md) -- enabling tools
- [Docker Compose](../../operations/docker-compose.md) -- browser profile
