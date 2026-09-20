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
  providers    Reload provider .env and worker config by recreating nginx/proxy/workers
  reload       Alias for providers; reload .env/config and recreate nginx/proxy/workers
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

ensure_tls_certificate() {
    local target_ip="${HOST_IP:-}"
    local env_file="${SCRIPT_DIR}/.env"
    local cert_dir="${SCRIPT_DIR}/nginx_certs"
    local cert_file="${cert_dir}/proxy.crt"
    local key_file="${cert_dir}/proxy.key"
    local renew_seconds="${CERT_RENEW_SECONDS:-2592000}"
    local cert_modulus
    local key_modulus
    local temp_dir

    # podman-compose reads .env itself, but shell functions do not. Read only
    # HOST_IP here rather than sourcing the complete file and placing secrets
    # into the service process environment.
    if [ -z "${target_ip}" ] && [ -f "${env_file}" ]; then
        target_ip="$(sed -n 's/^HOST_IP=//p' "${env_file}" | tail -n 1)"
    fi
    target_ip="${target_ip:-127.0.0.1}"

    if ! command -v openssl >/dev/null 2>&1; then
        echo "ERROR: openssl is required on the host to manage nginx TLS certificates." >&2
        return 1
    fi

    mkdir -p "${cert_dir}"

    if [ -s "${cert_file}" ] && [ -s "${key_file}" ] \
        && openssl x509 -in "${cert_file}" -noout >/dev/null 2>&1 \
        && openssl x509 -in "${cert_file}" -checkend "${renew_seconds}" -noout >/dev/null 2>&1 \
        && openssl x509 -in "${cert_file}" -checkip "${target_ip}" -noout >/dev/null 2>&1; then
        cert_modulus="$(openssl x509 -in "${cert_file}" -noout -modulus 2>/dev/null)" || return 1
        key_modulus="$(openssl rsa -in "${key_file}" -noout -modulus 2>/dev/null)" || return 1
        if [ "${cert_modulus}" = "${key_modulus}" ]; then
            echo "Reusing existing SSL certificate for IP: ${target_ip}"
            return 0
        fi
    fi

    echo "Generating SSL certificate for IP: ${target_ip}"
    umask 077
    temp_dir="$(mktemp -d "${cert_dir}/.proxy-cert.XXXXXX")"
    cat >"${temp_dir}/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${target_ip}

[v3_req]
subjectAltName = IP:${target_ip}
EOF
    if ! openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${temp_dir}/proxy.key" \
        -out "${temp_dir}/proxy.crt" \
        -config "${temp_dir}/openssl.cnf" \
        -extensions v3_req; then
        rm -rf "${temp_dir}"
        return 1
    fi
    chmod 600 "${temp_dir}/proxy.key"
    chmod 644 "${temp_dir}/proxy.crt"
    # Replace only after both files have been generated successfully.
    mv -f "${temp_dir}/proxy.key" "${key_file}"
    mv -f "${temp_dir}/proxy.crt" "${cert_file}"
    rm -f "${temp_dir}/openssl.cnf"
    rmdir "${temp_dir}" 2>/dev/null || true
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
    # nginx depends on litellm-proxy. Include it in the recreate set so
    # podman-compose removes dependents before replacing the proxy; selecting
    # only the proxy leaves the old nginx container holding a dependency and
    # causes Podman to reuse the stale proxy instead of applying config.yaml.
    # --no-deps keeps the already-running PostgreSQL container out of this
    # application reload; start is the command to recover a stopped database.
    "${COMPOSE[@]}" up -d --no-build --no-deps --force-recreate litellm-proxy "${worker_array[@]}" litellm-nginx
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
        ensure_tls_certificate
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
        ensure_tls_certificate
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
        ensure_tls_certificate
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
