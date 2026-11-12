#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env"

PROXY_URL="https://${LITELLM_BASE_URL}/key/delete" #"https://localhost/key/delete"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <key_alias>"
    echo "Example: $0 dev_jdoe"
    exit 1
fi

TARGET="$1"

echo "Revoking access for: ${TARGET}"

RESPONSE=$(curl -sk -X POST "$PROXY_URL" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"keys\": [\"${TARGET}\"]}")

if [[ "$RESPONSE" =~ "success" ]]; then
    echo "SUCCESS: Key '${TARGET}' has been revoked."
else
    echo "Error. Server response:"
    echo "$RESPONSE"
    exit 1
fi
