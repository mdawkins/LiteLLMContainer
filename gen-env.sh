#!/usr/bin/env bash
# Generate .env for compose — stable secrets only.
set -euo pipefail

# Safely source aliases only if running interactively and file exists
if [[ -f "${HOME}/.bash_aliases" ]]; then
    source "${HOME}/.bash_aliases" || true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Ensure .env exists without wiping existing content
touch "${ENV_FILE}"

# Helper function to get existing key value
get_env_val() {
    grep "^$1=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true
}

# Helper function to set or append key without wiping other entries
set_env_val() {
    local key="$1"
    local val="$2"
    if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
        # Replace existing key if empty
        if [[ -z "$(get_env_val "${key}")" ]]; then
            sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
        fi
    else
        # Append new key
        echo "${key}=${val}" >> "${ENV_FILE}"
    fi
}

# Read existing values
POSTGRES_PASSWORD=$(get_env_val "POSTGRES_PASSWORD")
LITELLM_MASTER_KEY=$(get_env_val "LITELLM_MASTER_KEY")
DATABASE_URL=$(get_env_val "DATABASE_URL")
VOLUMES_VAL=$(get_env_val "VOLUMES")

# Generate and set missing required variables
if [[ -z "${POSTGRES_PASSWORD}" ]]; then
    POSTGRES_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
    set_env_val "POSTGRES_PASSWORD" "${POSTGRES_PASSWORD}"
fi

if [[ -z "${LITELLM_MASTER_KEY}" ]]; then
    LITELLM_MASTER_KEY="sk-$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
    set_env_val "LITELLM_MASTER_KEY" "${LITELLM_MASTER_KEY}"
fi

if [[ -z "${DATABASE_URL}" ]]; then
    DATABASE_URL="postgresql://proxy_admin:${POSTGRES_PASSWORD}@litellm-db:5432/litellm"
    set_env_val "DATABASE_URL" "${DATABASE_URL}"
fi

if [[ -z "${VOLUMES_VAL}" ]]; then
    VOLUMES_DEFAULT="${VOLUMES:-${HOME}/Opt/Volumes}"
    set_env_val "VOLUMES" "${VOLUMES_DEFAULT}"
fi

chmod 600 "${ENV_FILE}"
echo "[gen-env] .env updated safely without overwriting existing keys."
