#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env"

BASE_URL="https://${LITELLM_BASE_URL}" #"https://localhost"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <key_alias>"
    echo "Example: $0 dev_jdoe"
    exit 1
fi

TARGET="$1"

echo "Querying LiteLLM for: ${TARGET}"
echo "------------------------------------------------------------"

# /key/info?key_alias= is broken in this LiteLLM version; resolve via /key/list first
RAW_KEY=$(curl -sk "${BASE_URL}/key/list?key_alias=${TARGET}" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['keys'][0] if d.get('keys') else '')" 2>/dev/null)

if [ -z "$RAW_KEY" ]; then
    echo "Error: key alias '${TARGET}' not found." >&2
    exit 1
fi

RESPONSE=$(curl -sk "${BASE_URL}/key/info?key=${RAW_KEY}" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}")

eval "$(echo "$RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('info', {})
def fmt(v, prefix=''):
    if v is None: return prefix + 'null'
    return prefix + str(v)
print('MAX_B=' + fmt(d.get('max_budget'), '') )
print('SPEND=' + fmt(d.get('spend'), '') )
print('RPM=' + fmt(d.get('rpm_limit'), '') )
print('TPM=' + fmt(d.get('tpm_limit'), '') )
print('BUDGET_DUR=' + str(d.get('budget_duration') or 'none'))
print('RESET_AT=' + str(d.get('budget_reset_at') or 'N/A'))
print('EXPIRES=' + str(d.get('expires') or 'Never'))
" 2>/dev/null || echo "MAX_B=error SPEND=error RPM=error TPM=error BUDGET_DUR=error RESET_AT=error EXPIRES=error")"

# Summarise token usage from spend logs (last 1000 requests)
LOGS=$(curl -sk "${BASE_URL}/spend/logs?api_key=${RAW_KEY}&limit=1000" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}")

eval "$(echo "$LOGS" | python3 -c "
import sys, json
rows = json.load(sys.stdin)
if not isinstance(rows, list): rows = []
prompt      = sum(r.get('prompt_tokens') or 0 for r in rows)
completion  = sum(r.get('completion_tokens') or 0 for r in rows)
total       = sum(r.get('total_tokens') or 0 for r in rows)
cached = 0
for r in rows:
    md    = r.get('metadata') or {}
    usage = md.get('usage_object') or {}
    cached += (usage.get('cache_read_input_tokens') or 0)
print(f'PROMPT_TOK={prompt}')
print(f'COMPLETION_TOK={completion}')
print(f'CACHED_TOK={cached}')
print(f'TOTAL_TOK={total}')
print(f'LOG_COUNT={len(rows)}')
" 2>/dev/null || echo "PROMPT_TOK=N/A COMPLETION_TOK=N/A CACHED_TOK=N/A TOTAL_TOK=N/A LOG_COUNT=0")"

echo "Alias:          ${TARGET}"
echo "Budget total:   \$${MAX_B}"
echo "Budget spent:   \$${SPEND}"
echo "Budget period:  ${BUDGET_DUR}  (resets ${RESET_AT})"
echo "Key expires:    ${EXPIRES}"
echo "Rate limit:     ${RPM} RPM / ${TPM} TPM"
echo "Tokens (last ${LOG_COUNT} requests):"
echo "  Prompt:       ${PROMPT_TOK}"
echo "  Completion:   ${COMPLETION_TOK}"
echo "  Cached:       ${CACHED_TOK}"
echo "  Total:        ${TOTAL_TOK}"
echo "------------------------------------------------------------"
