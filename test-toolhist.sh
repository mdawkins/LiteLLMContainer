#!/usr/bin/env bash
# Verifies the toolConfig shim: sends tool-history requests (with and without a
# `tools` array) to the proxy and prints the HTTP status per case.
#
# Usage: ./test-toolhist.sh [model ...]
#   Defaults to the three 5.5 Claude routes. Run from the repo root on the VM.
# Expected after the shim is deployed: every row is 200, including "no tools".
set -u
cd "$(dirname "$0")" || exit 1
set -a; . ./.env; set +a
BASE="${PROXY_URL:-https://${HOST_IP:-localhost}}"
MODELS=("$@")
[ ${#MODELS[@]} -eq 0 ] && MODELS=(openai/claude-haiku-5.5 openai/claude-sonnet-5.5 openai/claude-opus-5.5)

HIST='[{"role":"user","content":"hi"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"Read","arguments":"{}"}}]},{"role":"tool","tool_call_id":"call_1","content":"ok"},{"role":"user","content":"say done"}]'
TOOLS='[{"type":"function","function":{"name":"Read","description":"read a file","parameters":{"type":"object","properties":{}}}}]'
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

run() { # label model extra-json
  printf '{"model":"%s","max_tokens":64,"messages":%s%s}' "$2" "$HIST" "$3" > "$tmp/body.json"
  code=$(curl -sk -m 60 -o "$tmp/out.json" -w "%{http_code}" "$BASE/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
    --data @"$tmp/body.json")
  [ "$code" = 200 ] || fail=1
  echo "[$code] $1 :: $2 :: $(head -c 140 "$tmp/out.json" | tr '\n' ' ')"
}

for m in "${MODELS[@]}"; do
  run "no tools  " "$m" ""
  run "real tools" "$m" ",\"tools\":$TOOLS"
  echo
done
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES PRESENT"
exit $fail
