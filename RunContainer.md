# LLM-Lite Container Stack — LiteLLM Proxy for Amazon Bedrock

## Prerequisites

1. Create the persistent volume directory:
   ```sh
   mkdir -p ${VOLUMES}/litellm_pgvol/data
   ```

2. Ensure the `internal_net` podman network exists:
   ```sh
   podman network create internal_net
   ```

3. Place TLS certificates in `nginx_service/certs/` or mount externally:
   ```sh
   openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
     -keyout nginx_service/proxy.key \
     -out nginx_service/proxy.crt \
     -subj "/CN=localhost"
   ```

4. Set required environment variables:
   ```sh
   export CONTAINERS=$HOME/Build/Containers
   export VOLUMES=$HOME/Build/Volumes
   ```

## Build and Start

```sh
podman compose -f compose-litellm.yaml build
podman compose -f compose-litellm.yaml up -d
```

## Stop and Remove

```sh
podman compose -f compose-litellm.yaml down
```

## View Logs

```sh
podman logs -f litellm-proxy
podman logs -f litellm-db
podman logs -f litellm-nginx
```

## Execute Commands in Container

```sh
podman exec -it litellm-proxy /bin/bash
podman exec -it litellm-db /bin/bash
```

## Prune Unused Resources

```sh
podman system prune --all
```

## Generate User API Key

```sh
curl -X POST 'http://localhost:4000/key/generate' \
  -H 'Authorization: Bearer sk-your-master-proxy-key' \
  -H 'Content-Type: application/json' \
  -d '{
    "key_alias": "developer_team_alpha",
    "max_budget": 50.00,
    "budget_duration": "30d",
    "tpm_limit": 40000,
    "rpm_limit": 200
  }'
```

## Client Configuration

**Claude Code CLI:**
```sh
export ANTHROPIC_BASE_URL="https://your-rhel-box-ip"
export ANTHROPIC_API_KEY="sk-generated-user-token"
```

**VS Code / IDE Extensions:**
- Provider: OpenAI-Compatible
- Base URL: `https://your-rhel-box-ip/v1`
- API Key: `sk-generated-user-token`

**Claude Desktop:**
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

## Aliases

```sh
alias docker='podman'
prc() {
    podman stop "$1" && podman container rm "$1"
}
```
