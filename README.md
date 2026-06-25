# LLMLiteContainer

LiteLLM proxy stack for routing AI tool requests (Claude Code, VS Code extensions, Claude Desktop) through Amazon Bedrock on RHEL 9 with user authentication, rate limiting, token tracking, and TLS termination.

## Architecture

```
┌──────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   Client     │────▶│  litellm-nginx   │────▶│  litellm-proxy   │
│ (Claude CLI, │     │  (TLS Terminator │     │  (LiteLLM Proxy) │
│  VS Code,    │     │   port 443)      │     │   port 4000)     │
│  Desktop)    │     └──────────────────┘     └────────┬────────┘
└──────────────┘                                       │
                                                       ▼
                                              ┌──────────────────┐
                                              │   litellm-db      │
                                              │  (PostgreSQL 16)  │
                                              │   port 5432       │
                                              └──────────────────┘
```

Three services on a shared `internal_net` bridge network:

| Service | Container Name | Image | Purpose |
|---------|---------------|-------|---------|
| `litellm-db` | `litellm-db` | `postgres:18` | Persistent storage for user keys, budgets, rate limits, token usage |
| `litellm-proxy` | `litellm-proxy` | `ghcr.io/berriai/litellm:main-latest` | Translates OpenAI/Anthropic API calls to Amazon Bedrock; enforces auth and throttling |
| `litellm-nginx` | `litellm-nginx` | `nginx:alpine` | TLS termination on port 443; reverse proxy to LiteLLM on port 4000 |

## Directory Structure

```
LLMLiteContainer/
├── compose-litellm.yaml      # Podman Compose orchestration
├── prerequisites.sh          # One-shot setup (volumes, network, certs, images)
├── RunContainer.txt          # Quick-start commands and client config snippets
├── litellm_service/
│   ├── Dockerfile            # Bakes config.yaml into the LiteLLM image
│   └── config.yaml           # Model list, routing, caching, and drop_params settings
└── nginx_service/
    ├── Dockerfile            # Bakes nginx.conf into nginx:alpine
    └── nginx.conf            # TLS reverse proxy config for litellm-proxy:4000
```

## Configuration

### Environment Variables (compose-litellm.yaml)

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL connection string for LiteLLM persistent state |
| `AWS_ACCESS_KEY_ID` | AWS credential for Bedrock API calls |
| `AWS_SECRET_ACCESS_KEY` | AWS credential for Bedrock API calls |
| `AWS_REGION` | AWS region (default: `us-east-1`) |

### litellm_service/config.yaml

Defines available models mapped to Bedrock:

- `claude-3-5-sonnet` → `bedrock/invoke/us.anthropic.claude-3-5-sonnet-20241022-v2:0`
- `claude-3-5-haiku` → `bedrock/invoke/us.anthropic.claude-3-5-haiku-20241022-v1:0`
- `anthropic.claude-3-5-sonnet` → fallback alias for IDE extensions

Prompt caching is enabled via `cache_control_injection_points` on both `user` and `system` locations.

### nginx_service/nginx.conf

- HTTP (80) redirects to HTTPS (443)
- TLS 1.2/1.3 with strong ciphers
- Proxy buffering disabled for real-time token streaming
- 600s read timeout for long-running code generation
- 50MB max body for large context windows

## Deployment

```shell
# 1. Run prerequisites
chmod +x prerequisites.sh && ./prerequisites.sh

# 2. Build and start the stack
podman compose -f compose-litellm.yaml build
podman compose -f compose-litellm.yaml up -d

# 3. Generate a user API key
curl -X POST 'http://localhost:4000/key/generate' \
  -H 'Authorization: Bearer sk-your-master-proxy-key' \
  -H 'Content-Type: application/json' \
  -d '{"key_alias": "dev_user", "max_budget": 50.00, "budget_duration": "30d", "tpm_limit": 40000, "rpm_limit": 200}'
```

## Client Configuration

### Claude Code CLI
```shell
export ANTHROPIC_BASE_URL="https://your-rhel-box-ip"
export ANTHROPIC_API_KEY="sk-generated-user-token"
```

### VS Code / IDE Extensions
- **Provider**: OpenAI-Compatible
- **Base URL**: `https://your-rhel-box-ip/v1`
- **API Key**: `sk-generated-user-token`

### Claude Desktop
```json
{
  "mcpServers": {},
  "inference": {
    "provider": "openai-compatible",
    "baseURL": "https://your-rhel-box-ip/v1",
    "apiKey": "sk-generated-user-token"
  }
}
```

## Volume Layout

All persistent data lives under `~/Build/Volumes/`:

- `${VOLUMES}/litellm_pgvol/data/` — PostgreSQL database files (user keys, budgets, usage records)

## Network

`internal_net` is an external bridge network shared across compose stacks. Create it once:

```shell
podman network create internal_net
```
