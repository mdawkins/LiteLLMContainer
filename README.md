# LLMLiteContainer

LiteLLM proxy stack for routing AI tool requests (Claude Code, VS Code extensions, Claude Desktop) through Amazon Bedrock on RHEL 9 with user authentication, rate limiting, token tracking, and TLS termination.

## Architecture

```
┌──────────────┐     ┌──────────────────┐     ┌─────────────────┐     ┌──────────────────────┐
│   Client     │────▶│  litellm-nginx   │────▶│  litellm-proxy   │────▶│   Amazon Bedrock     │
│ (Claude CLI, │     │  (TLS Terminator │     │  (LiteLLM Proxy) │     │  (Converse API —     │
│  VS Code,    │     │   port 443)      │     │   port 4000)     │     │   cross-region       │
│  Desktop)    │     └──────────────────┘     └────────┬────────┘     │   inference profiles)│
└──────────────┘        bridge: internal_net   bridge: internal_net   └──────────────────────┘
                                                (IMDS via NAT hop)          AWS region
                                                         │
                                                         ▼
                                                ┌──────────────────┐
                                                │   litellm-db      │
                                                │  (PostgreSQL 18)  │
                                                │  127.0.0.1:5432   │
                                                └──────────────────┘
```

| Service | Container Name | Image | Network | Purpose |
|---------|---------------|-------|---------|---------|
| `litellm-db` | `litellm-db` | `postgres:18@sha256:32ca0af8...` | `internal_net` bridge | Persistent storage for user keys, budgets, rate limits, token usage |
| `litellm-proxy` | `litellm-proxy` | `ghcr.io/berriai/litellm:v1.92.0@sha256:9ef6f45b...` | `internal_net` bridge | Translates OpenAI/Anthropic API calls to Amazon Bedrock (Converse API); enforces auth and throttling; reaches IMDS (via NAT) for IAM credentials |
| `litellm-nginx` | `litellm-nginx` | `nginx:alpine@sha256:7068961d...` | `internal_net` bridge | TLS termination on port 443; proxies to `litellm-proxy:4000` |

All three images are pinned to immutable digests (see `litellm_service/Dockerfile`, `nginx_service/Dockerfile`, `compose-litellm.yaml`) rather than floating tags — never `:latest`/`:main-latest`. To bump a version: resolve the new tag's digest from the registry, review the upstream changelog, retest the stack, then update the pin deliberately. Never `podman pull` a floating tag into production.

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
├── harden-egress.sh          # Manual: restrict litellm-proxy's egress to DNS/IMDS/Bedrock(/RDS) only
├── scan-image.sh             # Scanner-agnostic image scan (Trivy/Grype/custom) + SBOM — run manually
├── rds-postgres.yaml         # Optional: CloudFormation for Amazon RDS Postgres (VM or ECS)
├── RunContainer.md           # Quick-start commands and client config snippets
├── REDEPLOY.md               # git pull + redeploy runbook for the AWS Linux VM
├── SecurityRemediationPlan.md # Cyber Security response — threat vector → control mapping
├── .github/workflows/
│   └── image-scan.yml        # Reference example only (NOT enabled) — wraps scan-image.sh;
│                              # scanner is swappable via the SCANNER env var, not fixed to Trivy
├── litellm_service/
│   ├── Dockerfile            # Bakes config.yaml into the LiteLLM image (pinned by digest)
│   └── config.yaml           # Model list, routing, caching, and drop_params settings
└── nginx_service/
    ├── Dockerfile            # Bakes nginx.conf + self-signed TLS cert into nginx:alpine (pinned by digest)
    └── nginx.conf            # TLS reverse proxy — proxies to litellm-proxy:4000 over internal_net
```

## Configuration

### Environment Variables (compose-litellm.yaml)

Variables are written to `.env` by `gen-env.sh`. AWS credentials are **not** stored in `.env` — `litellm-proxy` runs on the `internal_net` bridge and boto3 fetches them from the EC2 IMDS at request time (via the container's NAT hop), so they never expire.

| Variable | Source | Description |
|----------|--------|-------------|
| `POSTGRES_PASSWORD` | gen-env.sh (generated once, preserved) | Random 32-byte password for the PostgreSQL `proxy_admin` user |
| `LITELLM_MASTER_KEY` | gen-env.sh (generated once, preserved) | `sk-` prefixed master key for the LiteLLM proxy admin API |
| `DATABASE_URL` | gen-env.sh (computed once, preserved) | Postgres connection string. Defaults to the local `litellm-db` container; set manually to an RDS endpoint to switch (see "Optional: Amazon RDS" below) — once set, it's preserved across regeneration like the secrets above |
| `VOLUMES` | env or default | Base path for volume mounts — defaults to `$HOME/Build/Volumes` |

### Optional: Amazon RDS instead of the local Postgres container

`litellm-db` (a Podman container) is the default — no AWS dependency, fast local iteration. For production-grade persistence (automated backups, encryption at rest) on either the VM or a future ECS deployment, `rds-postgres.yaml` provisions an Amazon RDS PostgreSQL instance instead. **RDS is never a member of `internal_net`** — it gets its own ENI in your VPC subnets; isolation comes from its security group (ingress locked to the client's own SG) plus `PubliclyAccessible: false`, not container-network membership.

To switch:
1. Deploy `rds-postgres.yaml` (see the header comment in that file for the `aws cloudformation deploy` command) and note the `DBEndpointAddress` output.
2. Follow the 3-step comment block above the `litellm-db` service in `compose-litellm.yaml` (comment it out, drop the `depends_on`, set `DATABASE_URL` in `.env`).
3. If `harden-egress.sh` is in use, set `RDS_ENDPOINT_CIDR` before re-running it, so the proxy's egress lockdown allows the new destination.

IAM database authentication is available on the RDS instance but not wired into `litellm-proxy` — its 15-minute token expiry needs RDS Proxy or a refresh sidecar, tracked as an open item in `SecurityRemediationPlan.md`.

### AWS Authentication

`litellm-proxy` runs on the `internal_net` bridge and reaches the EC2 Instance Metadata Service (`169.254.169.254`) through the container's NAT hop rather than directly on the host interface. boto3 discovers the IAM role (`nhtsa-cdan.ec2.researcher.role`) automatically and rotates credentials in-process — no static keys, no restarts required when credentials refresh.

This requires `HttpPutResponseHopLimit` on the EC2 instance's metadata options to be at least `2` — AWS's IMDSv2 default of `1` only reaches processes on the instance's primary network interface, not a container behind Podman's bridge NAT. Set it with:

```shell
aws ec2 modify-instance-metadata-options \
  --instance-id <instance-id> \
  --http-tokens required \
  --http-put-response-hop-limit 2
```

### litellm_service/config.yaml

Defines available models mapped to Bedrock cross-region inference profiles (`us.anthropic.*`). Uses the `bedrock/` (Converse API) prefix — the modern path that supports native streaming.

| Alias | Bedrock profile |
|-------|----------------|
| `claude-sonnet-5` | `us.anthropic.claude-sonnet-5` |
| `claude-opus-4-8` | `us.anthropic.claude-opus-4-8` |
| `claude-sonnet-4-6` | `us.anthropic.claude-sonnet-4-6` |
| `claude-haiku-4-5` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |
| `claude-3-5-sonnet`, `claude-3-5-sonnet-v2`, `anthropic.claude-3-5-sonnet` | → sonnet-4-6 (legacy aliases) |
| `claude-3-5-haiku` | → haiku-4-5 (legacy alias) |

Prompt caching is enabled via `cache_control_injection_points` on both `user` and `system` locations.

### nginx_service/nginx.conf

- HTTP (80) redirects to HTTPS (443)
- TLS 1.2/1.3 with strong ciphers; self-signed cert generated at image build time
- Proxies to `litellm-proxy:4000` over the `internal_net` bridge
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

For pulling updates and redeploying on an already-running VM, see `REDEPLOY.md`.

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

All three services — `litellm-proxy`, `litellm-db`, and `litellm-nginx` — share the `internal_net` bridge and reach each other by container DNS name (`litellm-db:5432`, `litellm-proxy:4000`). None run with `network_mode: host`. `litellm-db` additionally exposes `127.0.0.1:5432` for host-local tooling; `litellm-proxy` reaches the EC2 IMDS through the bridge's NAT hop (see AWS Authentication above for the required `HttpPutResponseHopLimit` setting).

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

The host runs firewalld in the `drop` zone (default-deny). Ports 80 and 443 must be open for clients to reach nginx. Port 4000 (litellm-proxy) and 5432 (postgres) do **not** need firewall rules — both are only reached container-to-container over the `internal_net` bridge, and 5432 is additionally bound to `127.0.0.1` for host-local tooling.

```shell
sudo firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp
sudo firewall-cmd --reload
```

## Egress Filtering

`harden-egress.sh` restricts outbound traffic from the `litellm-proxy` container's bridge subnet (`internal_net`) to only DNS, the EC2 IMDS, and Amazon Bedrock — closing off a compromised dependency's ability to call home to an external C2 server. It's scoped entirely by source address (the bridge subnet), so it never touches the existing firewalld zone or any other service's rules on this host.

Not run automatically by `prerequisites.sh` — the Bedrock destination is an open question for the AWS architects (VPC interface endpoint vs. public IP-range allow-list; see `SecurityRemediationPlan.md`). Run it manually once that's decided:

```shell
# Option A — VPC interface endpoint (preferred)
BEDROCK_ENDPOINT_CIDR=10.0.5.10/32 ./harden-egress.sh

# Option B — public Bedrock IP ranges (fallback, review periodically).
# Resolve current ranges from https://ip-ranges.amazonaws.com/ip-ranges.json
# (filter service=="BEDROCK", region==your region) — do not guess these.
BEDROCK_PUBLIC_CIDRS="<cidr1> <cidr2> ..." ./harden-egress.sh
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
