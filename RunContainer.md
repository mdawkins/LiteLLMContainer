# Quick start

```shell
./prerequisites.sh
./stackctl.sh start
./stackctl.sh status
```

Edit `broker-registry.json` for accounts, models, costs, organizations, and
teams. Put provider secret values in `.env`, not in the registry.

```shell
# Validate and see deterministic public model names
./brokerctl.py validate
./brokerctl.py routes

# Live changes
./stackctl.sh models
./stackctl.sh access

# Reload provider environment without rebuilding images
./stackctl.sh reload
```

Import a Codex login after adding/enabling its account:

```shell
./brokerctl.py import-codex-auth primary --source ~/.codex/auth.json
./stackctl.sh reload
```

Create team-bound client keys:

```shell
./create-ai-user.sh -u developer-1 -T team-id -b 50 -d 30
./create-ai-user.sh -u ci-1 -T team-id -b 20 -d 30
```

OpenAI-compatible clients use `https://SERVER/v1`; Claude Code uses
`ANTHROPIC_BASE_URL=https://SERVER`. Both use the generated LiteLLM virtual key.

Only run `./stackctl.sh image` after Dockerfile, pinned digest, source patch, or
other image-build input changes.
