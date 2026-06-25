# LLM-Lite Setup — Design Rationale & Component Reference

This document explains the architecture decisions behind the stack and provides extended context on each component. For day-to-day commands, see `RunContainer.md`. For the canonical quick-start, see `README.md`.

---

## Why LiteLLM Proxy

LiteLLM acts as a central proxy that translates incoming OpenAI/Anthropic-format requests into Amazon Bedrock API calls. This lets every client tool (Claude Code, VS Code extensions, Claude Desktop) point at one internal endpoint rather than reaching Bedrock directly. It adds:

- **Per-user API keys** with individual budget caps, TPM, and RPM limits
- **Token usage tracking** stored in PostgreSQL per request
- **Prompt caching** injected automatically — up to 90% savings on repeated context
- **Model aliasing** so legacy client configs keep working as model IDs evolve

---

## Architecture

```
Client (Claude Code / VS Code / Claude Desktop)
        │  HTTPS :443
        ▼
  litellm-nginx          (nginx:alpine, internal_net bridge)
  TLS termination
        │  HTTP :4000
        ▼  (via host.containers.internal)
  litellm-proxy          (ghcr.io/berriai/litellm, host network)
  LiteLLM Proxy
        │  boto3 → IMDS
        ├──────────────────▶  Amazon Bedrock
        │
        │  TCP 127.0.0.1:5432
        ▼
  litellm-db             (postgres:18, internal_net bridge)
  PostgreSQL
```

`litellm-proxy` runs with `network_mode: host` for two reasons:

1. It needs to reach the EC2 Instance Metadata Service (`169.254.169.254`) to fetch IAM credentials automatically — no static AWS keys required.
2. It binds port `4000` on the host so nginx (on the internal bridge) can reach it via `host.containers.internal:4000`.

`litellm-db` exposes PostgreSQL on `127.0.0.1:5432` only — not accessible from outside the host. `litellm-nginx` is the only container with external-facing ports (80 and 443).

---

## Deployment

The stack is managed by `podman-compose`. The one-time setup script handles volume directories, the `internal_net` network, image pulls, `.env` generation, and systemd service installation:

```sh
chmod +x prerequisites.sh && ./prerequisites.sh
```

Build and start:

```sh
podman-compose -f compose-litellm.yaml build
podman-compose -f compose-litellm.yaml up -d
```

Stop:

```sh
podman-compose -f compose-litellm.yaml down
```

---

## Environment Variables

`gen-env.sh` writes `.env` on first run, then preserves existing values so secrets are not regenerated on subsequent runs. AWS credentials are **not** stored here — `litellm-proxy` fetches them from IMDS at request time.

| Variable | Description |
|----------|-------------|
| `POSTGRES_PASSWORD` | Random 32-byte password for PostgreSQL `proxy_admin` user |
| `LITELLM_MASTER_KEY` | `sk-` prefixed master key for the LiteLLM admin API |
| `VOLUMES` | Base path for volume mounts (default: `$HOME/Build/Volumes`) |

---

## TLS with Nginx

Nginx terminates TLS on port 443 and proxies plaintext to `litellm-proxy` on port 4000 via `host.containers.internal`. The self-signed certificate is generated at image build time inside `nginx_service/Dockerfile`.

`nginx_service/nginx.conf`:

```nginx
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    client_max_body_size 50M;

    server {
        listen 80;
        server_name _;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl;
        server_name _;

        ssl_certificate /etc/nginx/certs/proxy.crt;
        ssl_certificate_key /etc/nginx/certs/proxy.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;

        location / {
            proxy_pass http://host.containers.internal:4000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off;
            proxy_read_timeout 600s;
        }
    }
}
```

Key settings:
- `proxy_buffering off` — required for real-time token streaming
- `proxy_read_timeout 600s` — accommodates long-running code generation requests
- `client_max_body_size 50M` — handles large context windows

Because the cert is self-signed, clients connecting from developer machines may need TLS verification disabled:

```sh
# Claude Code CLI
export NODE_TLS_REJECT_UNAUTHORIZED=0
```

---

## Model Configuration (litellm_service/config.yaml)

Uses the `bedrock/` prefix (Converse API) — the modern path that supports native streaming. Cross-region inference profiles (`us.anthropic.*`) are used to avoid hard pinning to a single availability zone.

```yaml
model_list:

  # Claude Opus 4.8 — most capable, primary reasoning model
  - model_name: claude-opus-4-8
    litellm_params:
      model: bedrock/us.anthropic.claude-opus-4-8
      aws_region_name: us-east-1
      cache_control_injection_points:
        - location: "user"
        - location: "system"

  # Claude Sonnet 4.6 — balanced speed/capability, primary coding model
  - model_name: claude-sonnet-4-6
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-6
      aws_region_name: us-east-1
      cache_control_injection_points:
        - location: "user"
        - location: "system"

  # Claude Haiku 4.5 — fast/budget model
  - model_name: claude-haiku-4-5
    litellm_params:
      model: bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0
      aws_region_name: us-east-1
      cache_control_injection_points:
        - location: "user"
        - location: "system"

  # Legacy aliases — backwards-compat with existing client configs
  - model_name: claude-3-5-sonnet
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-6
      aws_region_name: us-east-1
      cache_control_injection_points:
        - location: "user"
        - location: "system"

  - model_name: anthropic.claude-3-5-sonnet
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-6
      aws_region_name: us-east-1
      cache_control_injection_points:
        - location: "user"
        - location: "system"

  - model_name: claude-3-5-haiku
    litellm_params:
      model: bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0
      aws_region_name: us-east-1
      cache_control_injection_points:
        - location: "user"
        - location: "system"

router_settings:
  routing_strategy: simple-shuffle

litellm_settings:
  drop_params: true
  drop_headers: ["anthropic-beta"]
```

`drop_params: true` prevents errors when IDEs send both `temperature` and `top_p` simultaneously. `drop_headers: ["anthropic-beta"]` strips experimental headers that Claude Code sends but Bedrock rejects.

---

## Prompt Caching

`cache_control_injection_points` tells LiteLLM to automatically insert cache checkpoints on `system` and `user` message locations. This works transparently — clients do not need to send any special headers.

Amazon Bedrock requirements for caching to activate:

- Minimum **1,024 tokens** in the prompt before a cache point is created. Shorter prompts bypass caching silently at normal pricing.
- Cache entries have a **5-minute TTL** from the last request. Any request that hits the cache resets the window.
- Context must match **exactly from the left** — Claude Code benefits heavily because it sends a static system prompt (file tree, project context) with every command.

To verify cache hits are occurring, watch the `cached_tokens` field in response metadata:

```sh
podman logs -f litellm-proxy
```

A response with active caching will show `cached_tokens` inside the `usage` block:

```json
"usage": {
  "prompt_tokens": 4500,
  "completion_tokens": 320,
  "total_tokens": 4820,
  "prompt_tokens_details": {
    "cached_tokens": 3400
  }
}
```

---

## Systemd Boot Persistence

`prerequisites.sh` installs `litellm-stack.service` into `/etc/systemd/system/` and enables it. The unit calls `gen-env.sh` at startup before launching the compose stack so `.env` is always present.

```sh
sudo systemctl start litellm-stack.service
sudo systemctl stop litellm-stack.service
sudo systemctl status litellm-stack.service
journalctl -u litellm-stack.service -f
```

---

## User Key Management

All scripts source `LITELLM_MASTER_KEY` from `.env` automatically — no manual export needed.

### create-ai-user.sh

Provisions a key with budget and rate limits and prints ready-to-use client config snippets.

```sh
./create-ai-user.sh -u dev_jdoe -b 50.00 -d 30
./create-ai-user.sh -u senior_dev -b 200.00 -d 30 -r 60 -t 200000
# -u username  -b budget_usd  -d duration_days  -r rpm  -t tpm
```

Default limits when `-r` and `-t` are omitted: 100 RPM, 200000 TPM.

The output includes copy-pasteable config for Claude Code CLI, VS Code extensions, and Claude Desktop.

### check-ai-user.sh

Prints budget spend, remaining balance, rate limits, and token usage aggregated from the last 1000 requests (including cache hit counts).

```sh
./check-ai-user.sh dev_jdoe
```

### revoke-ai-user.sh

Immediately deactivates a key, blocking further access across all connected tools.

```sh
./revoke-ai-user.sh dev_jdoe
```

### Manual key generation via curl

```sh
source .env
curl -X POST 'http://localhost:4000/key/generate' \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{
    "key_alias": "developer_team_alpha",
    "max_budget": 50.00,
    "budget_duration": "30d",
    "tpm_limit": 200000,
    "rpm_limit": 100
  }'
```

---

## Log Rotation

Container logs are capped at 50MB per container via `/etc/containers/containers.conf`:

```ini
[containers]
log_driver = "k8s-file"
log_size_max = 52428800
```

System journal limits in `/etc/systemd/journald.conf`:

```ini
[Journal]
SystemMaxUse=2G
SystemMaxFileSize=100M
MaxRetentionSec=14day
```

Apply journal changes:

```sh
sudo systemctl restart systemd-journald
```

---

## Rootless Podman

The stack runs as `$USER` with no root privileges. Two system settings are required (applied by `prerequisites.sh`):

**Unprivileged port binding:**

```sh
echo "net.ipv4.ip_unprivileged_port_start = 80" | sudo tee /etc/sysctl.d/99-podman-rootless.conf
sudo sysctl --system
```

**Linger (survive logout / persist across reboots):**

```sh
sudo loginctl enable-linger $USER
```

The systemd unit also sets `XDG_RUNTIME_DIR=/run/user/1118` so the rootless podman socket is reachable when the service manager launches the unit.

---

## Firewall

RHEL 9 runs firewalld in the `drop` zone (default-deny). Only ports 80 and 443 need to be open — port 4000 (litellm-proxy) and 5432 (postgres) are internal only.

```sh
sudo firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp
sudo firewall-cmd --reload
```
