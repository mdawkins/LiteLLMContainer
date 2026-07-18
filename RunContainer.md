# LiteLLM Container Stack — LiteLLM Proxy for Amazon Bedrock

## Prerequisites

Run once — creates volume dirs, `internal_net` network, pulls images, generates `.env`, and installs the systemd boot unit:

```sh
chmod +x prerequisites.sh && ./prerequisites.sh
```

## Build and Start

```sh
podman-compose -f compose-litellm.yaml build
podman-compose -f compose-litellm.yaml up -d
```

## Stop and Remove

```sh
podman-compose -f compose-litellm.yaml down
```

## systemd Boot Persistence

The stack auto-starts on boot via `litellm-stack.service`:

```sh
sudo systemctl start litellm-stack.service
sudo systemctl stop litellm-stack.service
sudo systemctl status litellm-stack.service
```

## View Logs

```sh
# Stack service logs
journalctl -u litellm-stack.service -f

# Per-container logs
podman logs -f litellm-proxy
podman logs -f litellm-db
podman logs -f litellm-nginx
```

## Execute Commands in Container

```sh
podman exec -it litellm-proxy /bin/bash
podman exec -it litellm-db /bin/bash
```

## User Key Management

All scripts read `LITELLM_MASTER_KEY` from `.env` automatically.

**Create a key:**
```sh
./create-ai-user.sh -u dev_jdoe -b 50.00 -d 30
./create-ai-user.sh -u senior_dev -b 200.00 -d 30 -r 60 -t 80000
# Options: -u username  -b budget_usd  -d duration_days  -r rpm  -t tpm
```

**Check spend and limits:**
```sh
./check-ai-user.sh dev_jdoe
```

**Revoke a key:**
```sh
./revoke-ai-user.sh dev_jdoe
```

**Manual key generation via curl:**
```sh
source .env
curl -X POST 'http://localhost:4000/key/generate' \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{
    "key_alias": "developer_team_alpha",
    "max_budget": 50.00,
    "budget_duration": "30d",
    "tpm_limit": 40000,
    "rpm_limit": 200
  }'
```

## Prune Unused Resources

```sh
podman system prune --all
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

## Available Models

| Model alias | Bedrock profile |
|-------------|----------------|
| `claude-sonnet-5` | `us.anthropic.claude-sonnet-5` |
| `claude-opus-4-8` | `us.anthropic.claude-opus-4-8` |
| `claude-sonnet-4-6` | `us.anthropic.claude-sonnet-4-6` |
| `claude-haiku-4-5` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |
| `claude-3-5-sonnet` | → sonnet-4-6 (legacy alias) |
| `claude-3-5-haiku` | → haiku-4-5 (legacy alias) |

## Rootless Podman Requirements

Applied automatically by `prerequisites.sh`. If setting up manually:

```sh
# Allow binding ports 80 and 443 without root
echo "net.ipv4.ip_unprivileged_port_start = 80" | sudo tee /etc/sysctl.d/99-podman-rootless.conf
sudo sysctl --system

# Keep containers running after logout and across reboots
sudo loginctl enable-linger $USER
```

The systemd unit sets `XDG_RUNTIME_DIR=/run/user/1118` so rootless podman can locate its socket when launched by the system service manager.

## Firewall

```sh
sudo firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp
sudo firewall-cmd --reload
```

## AWS Authentication

`litellm-proxy` runs on the `internal_net` bridge and authenticates to Bedrock via the EC2 IAM instance role (`nhtsa-cdan.ec2.researcher.role`), reaching IMDS through the container's NAT hop. Credentials rotate automatically in-process — no static keys, no credential refresh needed.

This requires `HttpPutResponseHopLimit >= 2` on the EC2 instance's metadata options (see `README.md` for the `aws ec2 modify-instance-metadata-options` command) — the default hop limit of `1` only reaches the host's primary interface, not a container behind bridge NAT.

## Aliases

```sh
alias docker='podman'
prc() {
    podman stop "$1" && podman container rm "$1"
}
```
