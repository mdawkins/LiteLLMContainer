#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_COMPOSE="${SCRIPT_DIR}/compose-litellm.yaml"
BROKER_COMPOSE="${SCRIPT_DIR}/.generated/compose-brokers.yaml"
COMPOSE=(podman-compose -f "${BASE_COMPOSE}" -f "${BROKER_COMPOSE}")

usage() {
    cat <<'EOF'
Usage: ./stackctl.sh COMMAND

  render       Validate registry, preserve/generate secrets, render worker compose
  start        Start without rebuilding, then reconcile models and access live
  models       Reconcile DB-backed routes live; no container restart
  access       Reconcile organizations/teams live; no container restart
  providers    Reload provider .env and worker config by recreating only proxy/workers
  reload       Alias for providers; reload .env/config and recreate proxy/workers
  tls          Recreate only nginx after HOST_IP/TLS configuration changes
  restart      Restart proxy/workers without rebuilding (does not reload .env)
  image        Rebuild changed local images and recreate the stack
  stop         Stop containers without deleting them
  status       Show container status
EOF
}

render() {
    "${SCRIPT_DIR}/gen-env.sh"
    python3 "${SCRIPT_DIR}/brokerctl.py" validate
    python3 "${SCRIPT_DIR}/brokerctl.py" ensure-env
    python3 "${SCRIPT_DIR}/brokerctl.py" render
}

preflight() {
    python3 "${SCRIPT_DIR}/brokerctl.py" preflight
}

workers() {
    python3 "${SCRIPT_DIR}/brokerctl.py" worker-services
}

wait_for_proxy() {
    local attempt
    for attempt in {1..60}; do
        if curl -ksSf https://localhost/health/liveliness >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "Timed out waiting for LiteLLM via https://localhost" >&2
    return 1
}

apply_models() {
    python3 "${SCRIPT_DIR}/brokerctl.py" apply-models \
        --base-url https://localhost --insecure --apply --prune
}

apply_access() {
    python3 "${SCRIPT_DIR}/brokerctl.py" apply-access \
        --base-url https://localhost --insecure --apply
}

reload_apps() {
    render
    preflight
    read -r -a worker_array <<<"$(workers)"
    "${COMPOSE[@]}" up -d --no-build --force-recreate litellm-proxy "${worker_array[@]}"
    wait_for_proxy
    apply_models
    apply_access
}

command="${1:-}"
case "${command}" in
    render)
        render
        ;;
    start)
        render
        preflight
        "${COMPOSE[@]}" up -d --no-build
        wait_for_proxy
        apply_models
        apply_access
        ;;
    models)
        old_fingerprint="$(cat "${SCRIPT_DIR}/.generated/runtime-fingerprint" 2>/dev/null || true)"
        render
        new_fingerprint="$(cat "${SCRIPT_DIR}/.generated/runtime-fingerprint")"
        if [[ -z "${old_fingerprint}" || "${old_fingerprint}" != "${new_fingerprint}" ]]; then
            echo "Provider environment/topology changed; run ./stackctl.sh reload before applying models." >&2
            exit 1
        fi
        preflight
        apply_models
        ;;
    access)
        python3 "${SCRIPT_DIR}/brokerctl.py" validate
        apply_access
        ;;
    providers|reload)
        reload_apps
        ;;
    tls)
        render
        "${COMPOSE[@]}" up -d --no-build --force-recreate litellm-nginx
        ;;
    restart)
        read -r -a worker_array <<<"$(workers)"
        "${COMPOSE[@]}" restart litellm-proxy "${worker_array[@]}"
        wait_for_proxy
        ;;
    image)
        render
        preflight
        "${COMPOSE[@]}" build
        "${COMPOSE[@]}" up -d --force-recreate
        wait_for_proxy
        apply_models
        apply_access
        ;;
    stop)
        "${COMPOSE[@]}" stop
        ;;
    status)
        "${COMPOSE[@]}" ps
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
