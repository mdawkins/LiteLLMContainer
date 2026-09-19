#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env"

if [[ "${LITELLM_BASE_URL}" == http://* || "${LITELLM_BASE_URL}" == https://* ]]; then
    PROXY_ROOT="${LITELLM_BASE_URL%/}"
else
    PROXY_ROOT="https://${LITELLM_BASE_URL%/}"
fi
PROXY_URL="${PROXY_ROOT}/key/generate"

usage() {
    echo "Usage: $0 -u <key_alias> -T <team_id> -b <budget_usd> -d <duration_days> [-r <rpm>] [-t <tpm>]"
    echo "Example: $0 -u dev_jdoe-1 -T research -b 50.00 -d 30 -r 100 -t 200000"
    exit 1
}

USERNAME=""
BUDGET=""
DURATION=""
TEAM_ID=""
RPM="100"
TPM="200000"

while getopts "u:T:b:d:r:t:h" opt; do
    case ${opt} in
        u) USERNAME="$OPTARG" ;;
        T) TEAM_ID="$OPTARG" ;;
        b) BUDGET="$OPTARG" ;;
        d) DURATION="$OPTARG" ;;
        r) RPM="$OPTARG" ;;
        t) TPM="$OPTARG" ;;
        *) usage ;;
    esac
done

if [ -z "$USERNAME" ] || [ -z "$TEAM_ID" ] || [ -z "$BUDGET" ] || [ -z "$DURATION" ]; then
    echo "Error: Missing required parameters." >&2
    usage
fi

BUDGET_DURATION="${DURATION}d"

echo "Creating token for: ${USERNAME}"
echo "Team: ${TEAM_ID} (model access inherited from the team)"
echo "Limits: \$${BUDGET} / ${BUDGET_DURATION}, ${RPM} RPM, ${TPM} TPM"
echo "------------------------------------------------------------"

PAYLOAD=$(python3 -c 'import json, sys; print(json.dumps({
    "key_alias": sys.argv[1],
    "team_id": sys.argv[2],
    "models": ["all-team-models"],
    "max_budget": float(sys.argv[3]),
    "budget_duration": sys.argv[4],
    "rpm_limit": int(sys.argv[5]),
    "tpm_limit": int(sys.argv[6]),
}))' "${USERNAME}" "${TEAM_ID}" "${BUDGET}" "${BUDGET_DURATION}" "${RPM}" "${TPM}")

RESPONSE=$(curl -sk -X POST "$PROXY_URL" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

if [[ "$RESPONSE" =~ \"key\":\"([^\"]+)\" ]]; then
    GENERATED_KEY="${BASH_REMATCH[1]}"
else
    echo "Error: Failed to generate token. Response:" >&2
    echo "$RESPONSE" >&2
    exit 1
fi

SERVER_IP=$(hostname -I | awk '{print $1}')

echo "SUCCESS"
echo "------------------------------------------------------------"
echo "Token: ${GENERATED_KEY}"
echo ""
echo "=== CLAUDE CODE CLI ==="
echo "export ANTHROPIC_BASE_URL=\"https://${SERVER_IP}\""
echo "export ANTHROPIC_API_KEY=\"${GENERATED_KEY}\""
echo "export NODE_TLS_REJECT_UNAUTHORIZED=0"
echo "export CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000"
echo ""
echo "=== VS CODE / IDE EXTENSION ==="
echo "Provider: OpenAI-Compatible"
echo "Base URL: https://${SERVER_IP}/v1"
echo "API Key:  ${GENERATED_KEY}"
echo ""
echo "=== CLAUDE DESKTOP JSON ==="
cat <<EOF
{
  "inference": {
    "provider": "openai-compatible",
    "baseURL": "https://${SERVER_IP}/v1",
    "apiKey": "${GENERATED_KEY}"
  }
}
EOF
