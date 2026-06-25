# LLMLiteContainer

LiteLLM proxy stack for routing AI tool requests (Claude Code, VS Code extensions, Claude Desktop) through Amazon Bedrock on RHEL 9 with user authentication, rate limiting, token tracking, and TLS termination.

## Architecture

```
┌──────────────┐     ┌──────────────────┐     ┌─────────────────┐     ┌──────────────────────┐
│   Client     │────▶│  litellm-nginx   │────▶│  litellm-proxy   │────▶│   Amazon Bedrock     │
│ (Claude CLI, │     │  (TLS Terminator │     │  (LiteLLM Proxy) │     │  (Converse API —     │
│  VS Code,    │     │   port 443)      │     │   port 4000)     │     │   cross-region       │
│  Desktop)    │     └──────────────────┘     └────────┬────────┘     │   inference profiles)│
└──────────────┘        bridge: internal_net    host network (IMDS)   └──────────────────────┘
                                                         │                    AWS region
                                                         ▼
                                                ┌──────────────────┐
                                                │   litellm-db      │
                                                │  (PostgreSQL 18)  │
                                                │  127.0.0.1:5432   │
                                                └──────────────────┘
```

| Service | Container Name | Image | Network | Purpose |
|---------|---------------|-------|---------|---------|
| `litellm-db` | `litellm-db` | `postgres:18` | `internal_net` bridge | Persistent storage for user keys, budgets, rate limits, token usage |
| `litellm-proxy` | `litellm-proxy` | `ghcr.io/berriai/litellm:main-latest` | `host` | Translates OpenAI/Anthropic API calls to Amazon Bedrock (Converse API); enforces auth and throttling; reaches IMDS directly for IAM credentials |
| `litellm-nginx` | `litellm-nginx` | `nginx:alpine` | `internal_net` bridge | TLS termination on port 443; proxies to `host.containers.internal:4000` |

## Directory Structure

```
LLMLiteContainer/
├── compose-litellm.yaml      # Podman Compose orchestration
├── gen-env.sh                # Generates .env (stable secrets only — AWS auth via IMDS)
├── prerequisites.sh          # One-shot setup (volumes, network, images, .env)
├── litellm-stack.service     # systemd unit — copy to /etc/systemd/system/ for boot persistence
├── create-ai-user.sh         # Provision a user API key with budget and rate limits
├── check-ai-user.sh          # Check a user's budget spend and rate limits
├── revoke-ai-user.sh         # Revoke a user API key immediately
├── RunContainer.md           # Quick-start commands and client config snippets
├── litellm_service/
│   ├── Dockerfile            # Bakes config.yaml into the LiteLLM image
│   └── config.yaml           # Model list, routing, caching, and drop_params settings
└── nginx_service/
    ├── Dockerfile            # Bakes nginx.conf + self-signed TLS cert into nginx:alpine
    └── nginx.conf            # TLS reverse proxy — proxies to host.containers.internal:4000
```

## Configuration

### Environment Variables (compose-litellm.yaml)

Variables are written to `.env` by `gen-env.sh`. AWS credentials are **not** stored in `.env` — `litellm-proxy` runs with `network_mode: host` and boto3 fetches them directly from the EC2 IMDS at request time, so they never expire.

| Variable | Source | Description |
|----------|--------|-------------|
| `POSTGRES_PASSWORD` | gen-env.sh (generated once, preserved) | Random 32-byte password for the PostgreSQL `proxy_admin` user |
| `LITELLM_MASTER_KEY` | gen-env.sh (generated once, preserved) | `sk-` prefixed master key for the LiteLLM proxy admin API |
| `VOLUMES` | env or default | Base path for volume mounts — defaults to `$HOME/Build/Volumes` |

### AWS Authentication

`litellm-proxy` runs with `network_mode: host`, giving it direct access to the EC2 Instance Metadata Service (`169.254.169.254`). boto3 discovers the IAM role (`nhtsa-cdan.ec2.researcher.role`) automatically and rotates credentials in-process — no static keys, no restarts required when credentials refresh.

### litellm_service/config.yaml

Defines available models mapped to Bedrock cross-region inference profiles (`us.anthropic.*`). Uses the `bedrock/` (Converse API) prefix — the modern path that supports native streaming.

| Alias | Bedrock profile |
|-------|----------------|
| `claude-opus-4-8` | `us.anthropic.claude-opus-4-8` |
| `claude-sonnet-4-6` | `us.anthropic.claude-sonnet-4-6` |
| `claude-haiku-4-5` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |
| `claude-3-5-sonnet`, `claude-3-5-sonnet-v2`, `anthropic.claude-3-5-sonnet` | → sonnet-4-6 (legacy aliases) |
| `claude-3-5-haiku` | → haiku-4-5 (legacy alias) |

Prompt caching is enabled via `cache_control_injection_points` on both `user` and `system` locations.

### nginx_service/nginx.conf

- HTTP (80) redirects to HTTPS (443)
- TLS 1.2/1.3 with strong ciphers; self-signed cert generated at image build time
- Proxies to `host.containers.internal:4000` (host-networked litellm-proxy)
- Proxy buffering disabled for real-time token streaming
- 600s read timeout for long-running code generation
- 50MB max body for large context windows

## Deployment

```shell
# 1. Run prerequisites (creates volumes, network, and .env)
chmod +x prerequisites.sh && ./prerequisites.sh

# 2. Build and start the stack
podman-compose -f compose-litellm.yaml build
podman-compose -f compose-litellm.yaml up -d
```

The stack auto-starts on boot via `litellm-stack.service` (installed by `prerequisites.sh`).

## User Key Management

All scripts read `LITELLM_MASTER_KEY` from `.env` automatically.

**Create a user key:**
```shell
./create-ai-user.sh -u dev_jdoe -b 50.00 -d 30
./create-ai-user.sh -u senior_dev -b 200.00 -d 30 -r 60 -t 80000
```

**Check a user's spend and limits:**
```shell
./check-ai-user.sh dev_jdoe
```

**Revoke a key:**
```shell
./revoke-ai-user.sh dev_jdoe
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

## Boot Persistence (systemd)

The stack is managed by `/etc/systemd/system/litellm-stack.service`, installed and enabled by `prerequisites.sh`. It calls `gen-env.sh` at startup before launching the compose stack, ensuring `.env` is always fresh.

```shell
# Manual control
sudo systemctl start litellm-stack.service
sudo systemctl stop litellm-stack.service
sudo systemctl status litellm-stack.service

# Logs via journald
journalctl -u litellm-stack.service -f
```

## Volume Layout

All persistent data lives under `~/Build/Volumes/`:

- `${VOLUMES}/litellm_pgvol/data/` — PostgreSQL database files (user keys, budgets, usage records)

## Network

`litellm-proxy` runs with `network_mode: host` for direct IMDS access. `litellm-db` and `litellm-nginx` share the `internal_net` bridge; the db exposes `127.0.0.1:5432` so the host-networked proxy can reach it, and nginx reaches the proxy via `host.containers.internal`.

`internal_net` is created once by `prerequisites.sh`:

```shell
podman network create internal_net
```

## Rootless Podman

The stack runs as `$USER` (UID 1118) with no root privileges. Two system settings are required and applied automatically by `prerequisites.sh`:

**1. Unprivileged port binding (ports 80 and 443)**

By default RHEL 9 only allows processes owned by root to bind ports below 1024. Lower the threshold to 80:

```shell
echo "net.ipv4.ip_unprivileged_port_start = 80" | sudo tee /etc/sysctl.d/99-podman-rootless.conf
sudo sysctl --system
```

**2. Linger (containers survive logout / persist across reboots)**

Without linger, the user's systemd session — and all containers — are killed when the last login session ends. Enable it once:

```shell
sudo loginctl enable-linger $USER
```

**3. XDG_RUNTIME_DIR in the systemd unit**

When a system-level unit (`/etc/systemd/system/`) runs as a non-root user, the rootless podman socket path (`/run/user/1118`) is not set in the environment automatically. The unit sets it explicitly:

```ini
Environment=XDG_RUNTIME_DIR=/run/user/1118
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1118/bus
```

These three settings together allow the rootless stack to bind ports 80/443, outlive interactive sessions, and be managed by the system service manager.

## Firewall

The host runs firewalld in the `drop` zone (default-deny). Ports 80 and 443 must be open for clients to reach nginx. Port 4000 (litellm-proxy) and 5432 (postgres) do **not** need firewall rules — 4000 is only accessed internally via `host.containers.internal` and 5432 is bound to `127.0.0.1`.

```shell
sudo firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp
sudo firewall-cmd --reload
```

## Log Rotation

Container logs are capped at 50MB per container via `/etc/containers/containers.conf`. System journal limits are set in `/etc/systemd/journald.conf`:

| Setting | Value |
|---------|-------|
| `SystemMaxUse` | 2G |
| `SystemMaxFileSize` | 100M |
| `MaxRetentionSec` | 14 days |

To view live proxy logs:
```shell
journalctl -u litellm-stack.service -f
podman logs -f litellm-proxy
```
