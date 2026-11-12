#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env"

BASE_URL="https://${LITELLM_BASE_URL}" #"https://localhost"

usage() {
    echo "Usage: $0 -u <username> [-b <budget_usd>] [-d <duration_days>] [-r <rpm>] [-t <tpm>]"
    echo "Example: $0 -u dev_jdoe -b 100.00 -r 150"
    echo "Only the flags you pass are changed; everything else on the key is left as-is."
    exit 1
}

USERNAME=""
BUDGET=""
DURATION=""
RPM=""
TPM=""

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

if [ -z "$USERNAME" ]; then
    echo "Error: Missing required -u <username>." >&2
    usage
fi

if [ -z "$BUDGET" ] && [ -z "$DURATION" ] && [ -z "$RPM" ] && [ -z "$TPM" ]; then
    echo "Error: Nothing to update — pass at least one of -b, -d, -r, -t." >&2
    usage
fi

# /key/info?key_alias= is broken in this LiteLLM version; resolve via /key/list first
RAW_KEY=$(curl -sk "${BASE_URL}/key/list?key_alias=${USERNAME}" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['keys'][0] if d.get('keys') else '')" 2>/dev/null)

if [ -z "$RAW_KEY" ]; then
    echo "Error: key alias '${USERNAME}' not found." >&2
    exit 1
fi

PAYLOAD_FIELDS="\"key\": \"${RAW_KEY}\""
[ -n "$BUDGET" ] && PAYLOAD_FIELDS="${PAYLOAD_FIELDS}, \"max_budget\": ${BUDGET}"
[ -n "$DURATION" ] && PAYLOAD_FIELDS="${PAYLOAD_FIELDS}, \"budget_duration\": \"${DURATION}d\""
[ -n "$RPM" ] && PAYLOAD_FIELDS="${PAYLOAD_FIELDS}, \"rpm_limit\": ${RPM}"
[ -n "$TPM" ] && PAYLOAD_FIELDS="${PAYLOAD_FIELDS}, \"tpm_limit\": ${TPM}"

echo "Updating token for: ${USERNAME}"
[ -n "$BUDGET" ] && echo "  max_budget      -> \$${BUDGET}"
[ -n "$DURATION" ] && echo "  budget_duration -> ${DURATION}d"
[ -n "$RPM" ] && echo "  rpm_limit       -> ${RPM}"
[ -n "$TPM" ] && echo "  tpm_limit       -> ${TPM}"
echo "------------------------------------------------------------"

RESPONSE=$(curl -sk -X POST "${BASE_URL}/key/update" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{${PAYLOAD_FIELDS}}")

if [[ "$RESPONSE" =~ \"key\":\"([^\"]+)\" ]]; then
    echo "SUCCESS: '${USERNAME}' updated."
else
    echo "Error: Failed to update key. Response:" >&2
    echo "$RESPONSE" >&2
    exit 1
fi
