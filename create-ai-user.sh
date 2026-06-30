#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env"

PROXY_URL="https://${LITELLM_BASE_URL}/key/generate" #"https://localhost/key/generate"

usage() {
    echo "Usage: $0 -u <username> -b <budget_usd> -d <duration_days> [-r <rpm>] [-t <tpm>]"
    echo "Example: $0 -u dev_jdoe -b 50.00 -d 30 -r 100 -t 200000"
    exit 1
}

USERNAME=""
BUDGET=""
DURATION=""
RPM="100"
TPM="200000"

while getopts "u:b:d:r:t:h" opt; do
    case ${opt} in
        u) USERNAME="$OPTARG" ;;
        b) BUDGET="$OPTARG" ;;
        d) DURATION="$OPTARG" ;;
        r) RPM="$OPTARG" ;;
        t) TPM="$OPTARG" ;;
        *) usage ;;
    esac
done

if [ -z "$USERNAME" ] || [ -z "$BUDGET" ] || [ -z "$DURATION" ]; then
    echo "Error: Missing required parameters." >&2
    usage
fi

BUDGET_DURATION="${DURATION}d"

echo "Creating token for: ${USERNAME}"
echo "Limits: \$${BUDGET} / ${BUDGET_DURATION}, ${RPM} RPM, ${TPM} TPM"
echo "------------------------------------------------------------"

RESPONSE=$(curl -sk -X POST "$PROXY_URL" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"key_alias\": \"${USERNAME}\",
    \"max_budget\": ${BUDGET},
    \"budget_duration\": \"${BUDGET_DURATION}\",
    \"rpm_limit\": ${RPM},
    \"tpm_limit\": ${TPM}
  }")

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
