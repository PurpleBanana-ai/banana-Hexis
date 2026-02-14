<!--
title: Embeddings
summary: Configure embedding models and services
read_when:
  - "You want to change the embedding model"
  - "You're troubleshooting embedding issues"
section: operations
-->

# Embeddings

Hexis needs an embedding service to generate vectors for memory storage and retrieval. The database calls the configured endpoint directly via HTTP.

## Quick Start

```bash
# Pull the default Ollama model
ollama pull embeddinggemma:300m-qat-q4_0

# Verify
hexis doctor    # checks embedding service health
```

## Configuration

Set in `.env`:

```bash
EMBEDDING_SERVICE_URL=http://host.docker.internal:11434/api/embed
EMBEDDING_MODEL_ID=embeddinggemma:300m-qat-q4_0
EMBEDDING_DIMENSION=768
```

## Providers

### Ollama (Default)

The default uses [Ollama](https://ollama.com/download) running on the host. Quantized models run fast on commodity hardware.

```bash
ollama pull embeddinggemma:300m-qat-q4_0   # run once
```

```bash
EMBEDDING_SERVICE_URL=http://host.docker.internal:11434/api/embed
EMBEDDING_MODEL_ID=embeddinggemma:300m-qat-q4_0
EMBEDDING_DIMENSION=768
```

### HuggingFace TEI

Uncomment the `embeddings` service in `docker-compose.yml`:

```bash
EMBEDDING_SERVICE_URL=http://embeddings:80/embed
EMBEDDING_MODEL_ID=unsloth/embeddinggemma-300m
EMBEDDING_DIMENSION=768
```

Note: TEI is CPU-only with float32 precision -- no quantized model support.

### OpenAI-Compatible Endpoints

Point at any OpenAI-compatible embedding API (OpenAI, vLLM, LiteLLM, etc.):

```bash
EMBEDDING_SERVICE_URL=https://api.openai.com/v1/embeddings
EMBEDDING_MODEL_ID=text-embedding-3-small
EMBEDDING_DIMENSION=1536
```

## Changing Dimensions

If you change `EMBEDDING_DIMENSION` on an existing database, you must reset the volume so vector columns and HNSW indexes are recreated:

```bash
hexis reset   # wipes all data and re-initializes
```

## Diagnosing Issues

```bash
hexis doctor    # identifies the provider from URL and gives specific fix steps
```

Common issues:

- **Ollama not running** -- start Ollama and ensure the model is pulled
- **Model not found** -- run `ollama pull <model_id>`
- **Wrong dimension** -- ensure `EMBEDDING_DIMENSION` matches the model's output dimension
- **Docker networking** -- the DB container uses `host.docker.internal` to reach host services

## How It Works

The database calls the embedding service directly via the `get_embedding(text[])` SQL function. Embeddings are cached in the `embedding_cache` table keyed by content hash. The application layer never sees vectors.

## Related

- [Environment Variables](environment-variables.md) -- embedding config variables
- [Database](database.md) -- schema and extensions
- [Troubleshooting](troubleshooting.md) -- embedding troubleshooting
