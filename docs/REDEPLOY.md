# Redeploy runbook

```shell
cd /path/to/LiteLLMContainer
git status
OLD_SHA=$(git rev-parse HEAD)
git pull
git diff --stat "$OLD_SHA"..HEAD
```

Choose the smallest applicable operation:

```shell
# Registry model/pricing edits only: live, no container restart
./stackctl.sh models

# Registry organization/team edits only: live, no container restart
./stackctl.sh access

# .env provider tokens, Codex accounts, or config.yaml: recreate app processes
./stackctl.sh reload

# Dockerfiles, patch files, nginx build inputs, or pinned digests: rebuild
./stackctl.sh image
```

The current image pins are LiteLLM v1.101.0, nginx 1.31.5-alpine3.24, and
PostgreSQL 18.6. The PostgreSQL change is a minor release within major version
18, so it does not require a dump/restore or `pg_upgrade`; take a normal backup
before any production change and keep the volume. A future PostgreSQL major
upgrade must use a separate migration plan.

`reload` is the safe no-build path for `.env` or `litellm_service/config.yaml`
changes. It re-renders the generated broker compose file, recreates nginx, the
LiteLLM proxy, and any Codex workers in dependency order, waits for health, and
reapplies managed models and access grants. `providers` remains an equivalent
compatibility alias.

If deployment helpers or the systemd unit changed, rerun the idempotent setup
before selecting the operation:

```shell
./prerequisites.sh
```

`prerequisites.sh` builds because it is the initial/upgrade path. The installed
systemd unit does not build on every boot and does not delete containers when
stopped.

Verify:

```shell
./stackctl.sh status
systemctl status litellm-stack.service
journalctl -u litellm-stack.service -n 100 --no-pager
podman logs --tail 100 litellm-proxy
curl -sk https://localhost/v1/models \
  -H "Authorization: Bearer $(sed -n 's/^LITELLM_MASTER_KEY=//p' .env)"
```

If an image upgrade fails while applying the source patch, do not bypass the
failure. Compare the new upstream streaming adapter with
`litellm_service/apply_patch.py`, update the reviewed source contract and its
tests, and rebuild.

For rollback, restore the recorded revision deliberately and repeat the
applicable operation. `.env`, PostgreSQL, and Codex auth volumes are not stored
in Git and survive a source rollback. A registry rollback followed by
`stackctl models` prunes only stale routes previously managed by `brokerctl`.
