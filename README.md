# LiteLLM multi-broker gateway

Rootless Podman stack for deterministic routing across three broker types:

- Amazon Bedrock, using the instance role or an explicitly configured role
- USAI, using one named API-key environment variable per account
- Codex/ChatGPT, using one isolated internal LiteLLM worker per login

The public route name always identifies one broker account and one upstream
model:

```text
bedrock/instance-role/claude-sonnet-5
usai/primary/gpt-5.4
codex/primary/gpt-5.3-codex
```

There are no cross-broker fallbacks, router aliases, or duplicate deployments
behind one name. A request either reaches the broker named in its route or
fails visibly.

## Configuration model

`broker-registry.json` is the declarative source of truth for broker accounts,
routes, organizations, and teams. It stores only secret references such as
`DOT_USAI_API_KEY`; secret values remain in the gitignored `.env` file or in a
Codex auth volume.

`litellm_service/config.yaml` contains only stable proxy settings. Models are
stored in PostgreSQL (`store_model_in_db: true`) and reconciled through
LiteLLM's model-management API, so model edits take effect without restarting
the proxy.

`brokerctl.py` validates the registry before rendering or applying it. It
rejects fallback keys, duplicate public routes, unknown model grants, and team
grants wider than their parent organization.

## First deployment

```shell
./prerequisites.sh
./stackctl.sh start
```

`prerequisites.sh` performs the initial pinned-image build. Normal starts and
boots do not rebuild images.

## Change matrix

| Change | Command | Effect |
|---|---|---|
| Models, prices, capabilities | `./stackctl.sh models` | Live DB reconciliation; no restart |
| Organization/team grants | `./stackctl.sh access` | Live DB reconciliation; no restart |
| USAI token, AWS provider environment, Codex worker/auth config | `./stackctl.sh providers` | Recreates proxy/Codex workers; no image build and no `down` |
| `.env` or infrastructure-only `config.yaml` | `./stackctl.sh reload` | Recreates proxy/Codex workers; no image build and no `down` |
| `HOST_IP` or TLS certificate inputs | `./stackctl.sh tls` | Recreates only nginx |
| Dockerfile, source patch, nginx files, or image digest | `./stackctl.sh image` | Builds and recreates the stack |
| Ordinary boot/start | `./stackctl.sh start` | Starts existing containers/images and reconciles live state |

The nginx self-signed certificate is persisted in `nginx_certs/`. `stackctl.sh`
uses the host's `openssl` command to reuse it when the certificate and RSA key
are valid, match `HOST_IP`, and have more than 30 days remaining. It regenerates
the pair only when either file is missing, invalid, mismatched, changed to a
different IP, or near expiry. The nginx image does not install packages at
build time or generate certificates inside the container.

Container environment is fixed when a process starts, so an edited `.env`
cannot be hot-reloaded into an existing container. Recreation is required, but
deleting the stack and rebuilding images is not. PostgreSQL is not recreated by
`reload`/`providers`.

`stackctl models` fingerprints the rendered provider topology. If an edit also
changes environment mappings or Codex worker configuration, it refuses the
live-only path and requires `stackctl providers` first.

The host helper scripts require Python 3.7 or newer; Python 3.10+ is
recommended. On older VMs, install a supported Python and create
`./.venv`, then activate it before running `brokerctl.py`, `stackctl.sh`, or
`prerequisites.sh`. The systemd unit prefers that virtualenv automatically.

Do not casually change `POSTGRES_PASSWORD`, `DATABASE_URL`, or
`LITELLM_SALT_KEY`. Provider-token changes are safe with `providers`; database
credential migration is a separate administrative operation. The salt is
generated once and is required to decrypt provider values stored in the DB.

## Multiple broker accounts

Add another object to `accounts` with a distinct `id`. For example, a second
USAI account uses another environment reference:

```json
{
  "broker": "usai",
  "id": "program-b",
  "enabled": true,
  "api_base": "https://api.dot.usai.gov/api/v1",
  "api_key_env": "DOT_USAI_PROGRAM_B_API_KEY",
  "models": [
    {"route": "gpt-5.4", "upstream": "gpt_5_4_default_v2"}
  ]
}
```

Put `DOT_USAI_PROGRAM_B_API_KEY=...` in `.env`, then run:

```shell
./stackctl.sh reload
```

For Bedrock, add another Bedrock account and set `aws_role_name` on it. Prefer
instance/assumed roles to static AWS keys. If a broker account cannot use role
assumption, the optional `aws_access_key_id_env`,
`aws_secret_access_key_env`, and `aws_session_token_env` fields reference
separate `.env` values; they never contain the values themselves. The account
ID remains part of every route, so access and spend attribution cannot silently
cross accounts.

### Codex accounts

LiteLLM's ChatGPT authenticator uses one process-global auth location. Each
Codex login therefore gets its own internal worker container and writable auth
directory. The whole host `~/.codex` directory is not mounted.

1. Add/enable a `codex` account in `broker-registry.json`.
2. Import only the required credentials into its volume:

   ```shell
   ./brokerctl.py import-codex-auth primary --source ~/.codex/auth.json
   ```

3. Render/recreate the provider processes and apply the routes:

   ```shell
   ./stackctl.sh reload
   ```

The importer converts Codex's nested token structure to the flattened format
expected by LiteLLM, writes it atomically with mode `0600`, and never prints
token values. The worker owns a copy because refresh can update the auth file.
Codex access tokens are short-lived; continued operation depends on the refresh
credential remaining valid. Revocation, policy, logout, or account changes can
end the session earlier, so there is no safe fixed lifetime to assume.

Codex subscription traffic does not expose token-priced API billing through
this integration. Codex routes are explicitly marked
`subscription-cost-not-reported`; the gateway does not invent dollar costs.

## Organizations, teams, and multiple client tokens

Organizations and teams contain route allowlists. Wildcards are expanded by
`brokerctl.py` to the current explicit routes before LiteLLM receives them:

```json
{
  "organizations": [
    {
      "id": "research-org",
      "alias": "Research",
      "models": ["bedrock/instance-role/*", "usai/primary/*"]
    }
  ],
  "teams": [
    {
      "id": "red-team",
      "alias": "Red Team",
      "organization_id": "research-org",
      "models": ["bedrock/instance-role/claude-sonnet-5", "usai/primary/gpt-5.4"]
    }
  ]
}
```

Apply access changes live:

```shell
./stackctl.sh access
```

LiteLLM documents parts of organization-level access control as Premium. The
registry and API reconciliation are implemented here, but the installed
license ultimately determines which organization features LiteLLM will accept;
`brokerctl` surfaces that API error instead of weakening the policy to a team-
only fallback.

Create any number of client tokens for the same team by running the command
with different aliases. Each generated key uses `models: ["all-team-models"]`,
so model authority remains on the team rather than being copied into the key:

```shell
./create-ai-user.sh -u red-ci -T red-team -b 50 -d 30
./create-ai-user.sh -u red-developer-1 -T red-team -b 25 -d 30
```

Existing unrestricted keys are not automatically made safe by creating teams.
Audit, update, or revoke them before treating team allowlists as an enforcement
boundary. The master key remains an administrator credential with full access.

## Model discovery and costs

USAI's current catalog can be compared with an account without publishing new
routes:

```shell
./brokerctl.py discover-usai primary
```

Discovery deliberately does not auto-add or auto-grant models. A newly exposed
upstream model may have unknown price, capability, policy, or entitlement
semantics. Review it, add it to the registry, assign a price/capability record,
then run `stackctl models`. This keeps updates easy without turning upstream
catalog drift into an access-control change.

USAI routes use the explicit registry prices. Bedrock uses LiteLLM's pricing
catalog unless a registry model overrides it. Codex subscription routes report
usage but not fabricated marginal cost.

## Upgrade-patch safety

The local Anthropic streaming patch is applied at image build time. Its test
suite verifies the exact reviewed upstream block, syntax, idempotence, and
fail-closed behavior. If a new LiteLLM digest changes that block, the image
build stops and requires review instead of silently applying a stale patch.

```shell
python3 -m unittest -v litellm_service/test_apply_patch.py
./stackctl.sh image
```

## Useful commands

```shell
./brokerctl.py validate
./brokerctl.py routes
./stackctl.sh status
podman logs --tail 100 litellm-proxy
curl -sk https://localhost/v1/models \
  -H "Authorization: Bearer $(sed -n 's/^LITELLM_MASTER_KEY=//p' .env)"
```

The systemd unit is installed by `prerequisites.sh`. It starts existing images
through `stackctl start` and stops containers without deleting them.

If `harden-egress.sh` is used, supply reviewed CIDRs for every enabled broker.
The script now fails before changing firewalld when USAI or Codex is enabled
without its corresponding allowlist. Public broker/CDN addresses can change;
a controlled egress proxy or private endpoint is safer than a one-time DNS
snapshot.
