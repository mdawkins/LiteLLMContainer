# Design reference

The current architecture and operating instructions are in `README.md`.

The important design properties are:

- Every model name is a deterministic `broker/account/model` route.
- Bedrock, USAI, and Codex accounts are declared in `broker-registry.json`.
- Broker secrets are referenced by environment name and never stored in the registry.
- Codex logins are isolated one per internal worker process.
- Models and organization/team grants are reconciled live through LiteLLM's DB APIs.
- `.env` changes recreate only affected application containers; they do not require image builds.
- Image builds are reserved for Dockerfile, pinned-digest, patch, or other build-input changes.
- The source patch fails closed when an upgraded LiteLLM image no longer matches the reviewed block.

See `RunContainer.md` for the short command list and `REDEPLOY.md` for upgrades.
