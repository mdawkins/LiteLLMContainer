# Redeploy Runbook — AWS Linux VM

Steps to pull a new revision of this repo and redeploy the LiteLLM stack on
an already-running RHEL/AWS Linux VM. This is for the VM target only — there
is nothing to redeploy on ECS since no ECS resources exist yet.

## 1. Pre-flight

```shell
cd /Build/Containers/LLMLiteContainer   # or wherever this repo lives on the VM
git status
```

If `git status` shows uncommitted local changes, stop and resolve them first
(commit, stash, or discard deliberately) — a VM checkout should stay a clean
mirror of a known commit. Note the current commit as your rollback target:

```shell
OLD_SHA=$(git rev-parse HEAD)
echo "$OLD_SHA"   # write this down / keep the shell open
```

## 2. Pull

```shell
git pull
```

## 3. Review what changed, re-run prerequisites if needed

```shell
git log --oneline "$OLD_SHA"..HEAD
git diff --stat "$OLD_SHA"..HEAD
```

`prerequisites.sh` is idempotent — every step checks current state before
acting, so re-running it is always safe. If `prerequisites.sh`,
`litellm-stack.service`, `gen-env.sh`, `harden-egress.sh`, or anything
touching the volume/network setup changed — **or you're not sure** — just
re-run it rather than hand-deciding:

```shell
./prerequisites.sh
```

## 4. Restart the stack

```shell
sudo systemctl restart litellm-stack.service
```

No separate `podman-compose build` step is needed first: the unit's
`ExecStart` already runs `podman-compose -f compose-litellm.yaml up -d
--build` on every start, which rebuilds `litellm-proxy`/`litellm-nginx` from
the current source and the current pinned base-image digests. `ExecStartPre`
also re-runs `gen-env.sh`, which preserves `POSTGRES_PASSWORD`,
`LITELLM_MASTER_KEY`, and `DATABASE_URL` across the restart.

## 5. Verify

```shell
systemctl status litellm-stack.service        # expect active (exited) — it's a oneshot unit
podman ps                                      # expect litellm-db, litellm-proxy, litellm-nginx all Up,
                                                # litellm-db additionally (healthy)
journalctl -u litellm-stack.service -n 50 --no-pager
podman logs --tail 50 litellm-proxy            # check for DB-connect or Bedrock-auth errors
```

Smoke test — exercises TLS termination, proxy auth, and (if DB-backed) key
validation in one call:

```shell
curl -sk https://localhost/v1/models \
  -H "Authorization: Bearer $(grep LITELLM_MASTER_KEY .env | cut -d= -f2-)"
```

Expect an HTTP 200 with the configured model list. Anything else — stop here
and go to Rollback.

## 6. Rollback (only if step 5 fails)

```shell
git log --oneline -10          # confirm the last-known-good SHA (OLD_SHA from step 1)
git checkout "$OLD_SHA"
```

Then repeat steps 3–5 (re-run `prerequisites.sh` if the failed revision
touched infra files, `systemctl restart`, re-verify). `.env` is gitignored
and untouched by `git checkout`, so `gen-env.sh`'s preserve-on-regen logic
means `POSTGRES_PASSWORD`, `LITELLM_MASTER_KEY`, and `DATABASE_URL` survive
the rollback unchanged.

## 7. Switching persistence to Amazon RDS on this pass

Only relevant if you're also migrating off the local `litellm-db` container
during this redeploy — see the "Optional: Amazon RDS" section in
`README.md` and `rds-postgres.yaml`. In short: follow the 3-step comment
block above the `litellm-db` service in `compose-litellm.yaml`, set
`DATABASE_URL` in `.env` to the RDS endpoint, then continue from step 4
above.
