#!/usr/bin/env bash
# Restricts outbound traffic from the complete LiteLLM bridge subnet. Every
# enabled external broker must have an explicit destination allowlist.
# See SecurityRemediationPlan.md, open question #1.
#
# NOT wired into prerequisites.sh and NOT run automatically: the Bedrock
# destination (VPC interface endpoint vs. public IP-range allow-list) is an
# open question for the AWS architects. Run this manually once that's decided.
#
# Scoping: every rule below is filtered by `source address="<internal_net
# subnet>"`. This does not create a policy-wide default deny, and does not
# touch the existing firewalld zone or any other service's rules on this
# host — only traffic sourced from litellm's own bridge subnet is affected.
set -euo pipefail

NETWORK_NAME="${NETWORK_NAME:-internal_net}"
POLICY_NAME="litellm-egress"

# --- Bedrock destination — set exactly one of these before running ---
# Option A (preferred): VPC interface endpoint ENI IP(s) for Bedrock. Doesn't
# rot as AWS's public IP ranges change.
BEDROCK_ENDPOINT_CIDR="${BEDROCK_ENDPOINT_CIDR:-}"     # e.g. 10.0.5.10/32
# Option B (fallback, WEAK — interim only): AWS does not publish a
# BEDROCK-tagged entry in https://ip-ranges.amazonaws.com/ip-ranges.json.
# Bedrock's regional endpoints resolve into the generic "AMAZON" catch-all
# service, which for a single region is hundreds of CIDR blocks — effectively
# all of AWS's public IP space there, not a Bedrock-specific allow-list. This
# blocks non-AWS-hosted C2 but NOT C2 rented on AWS infrastructure, which is
# most of what this control exists to stop. Use only as a documented,
# temporary stopgap while the VPC endpoint (Option A) is arranged, and review
# the CIDR set periodically since it still changes. See SecurityRemediationPlan.md,
# open question #1.
BEDROCK_PUBLIC_CIDRS="${BEDROCK_PUBLIC_CIDRS:-}"       # space-separated CIDRs

# USAI and Codex/ChatGPT use public HTTPS endpoints whose addresses may change.
# Supply reviewed CIDRs from the network team, or route these destinations
# through a controlled egress proxy with a stable CIDR. Do not snapshot DNS
# answers once and assume they are permanent.
USAI_ENDPOINT_CIDRS="${USAI_ENDPOINT_CIDRS:-}"         # space-separated CIDRs
CODEX_ENDPOINT_CIDRS="${CODEX_ENDPOINT_CIDRS:-}"       # space-separated CIDRs

# Required only for Bedrock accounts that assume another role instead of using
# the instance role directly.
STS_ENDPOINT_CIDRS="${STS_ENDPOINT_CIDRS:-}"           # space-separated CIDRs

# --- Amazon RDS (optional) — set only if litellm-proxy has been switched to
# an RDS-backed DATABASE_URL (see rds-postgres.yaml). Traffic to the local
# litellm-db container never leaves the host and doesn't need this; traffic
# to RDS routes off-host and would otherwise hit the catch-all reject below.
RDS_ENDPOINT_CIDR="${RDS_ENDPOINT_CIDR:-}"             # e.g. 10.0.6.20/32
RDS_PORT="${RDS_PORT:-5432}"

ENABLED_BROKERS=$(python3 - "$(dirname "${BASH_SOURCE[0]}")/broker-registry.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    registry = json.load(handle)
print(" ".join(sorted({a["broker"] for a in registry.get("accounts", []) if a.get("enabled")})))
PY
)

if [[ " ${ENABLED_BROKERS} " == *" bedrock "* && -z "${BEDROCK_ENDPOINT_CIDR}" && -z "${BEDROCK_PUBLIC_CIDRS}" ]]; then
    echo "ERROR: set BEDROCK_ENDPOINT_CIDR or BEDROCK_PUBLIC_CIDRS before running." >&2
    echo "  This is the open question for the AWS architects (SecurityRemediationPlan.md)." >&2
    echo "  Example: BEDROCK_ENDPOINT_CIDR=10.0.5.10/32 ./harden-egress.sh" >&2
    exit 1
fi
if [[ " ${ENABLED_BROKERS} " == *" usai "* && -z "${USAI_ENDPOINT_CIDRS}" ]]; then
    echo "ERROR: USAI is enabled; set USAI_ENDPOINT_CIDRS before applying deny-by-default egress." >&2
    exit 1
fi
if [[ " ${ENABLED_BROKERS} " == *" codex "* && -z "${CODEX_ENDPOINT_CIDRS}" ]]; then
    echo "ERROR: Codex is enabled; set CODEX_ENDPOINT_CIDRS before applying deny-by-default egress." >&2
    exit 1
fi

SUBNET=$(podman network inspect "${NETWORK_NAME}" --format '{{(index .Subnets 0).Subnet}}' 2>/dev/null || true)
if [[ -z "${SUBNET}" ]]; then
    echo "ERROR: could not resolve subnet for podman network '${NETWORK_NAME}'." >&2
    echo "  Has prerequisites.sh been run yet? (creates the network)" >&2
    exit 1
fi

echo "Restricting egress for ${SUBNET} (podman network: ${NETWORK_NAME})..."

if ! sudo firewall-cmd --permanent --info-policy="${POLICY_NAME}" &>/dev/null; then
    sudo firewall-cmd --permanent --new-policy="${POLICY_NAME}"
    sudo firewall-cmd --permanent --policy="${POLICY_NAME}" --add-ingress-zone=ANY
    sudo firewall-cmd --permanent --policy="${POLICY_NAME}" --add-egress-zone=ANY
    echo "  Created policy '${POLICY_NAME}' (target left at default — this policy adds"
    echo "  no catch-all rule; only the source-scoped rich rules below take effect)."
fi

# Allow rules run first (negative priority). DNS is required to resolve broker
# hostnames. Internal traffic preserves proxy/worker/database connectivity.
sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
    --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" port port=\"53\" protocol=\"udp\" accept"
sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
    --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" port port=\"53\" protocol=\"tcp\" accept"
sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
    --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" destination address=\"${SUBNET}\" accept"
sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
    --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" destination address=\"169.254.169.254/32\" port port=\"80\" protocol=\"tcp\" accept"

allow_https_cidrs() {
    local label="$1"
    local cidrs="$2"
    local cidr
    [[ -z "${cidrs}" ]] && return 0
    for cidr in ${cidrs}; do
        python3 -c 'import ipaddress,sys; ipaddress.ip_network(sys.argv[1], strict=False)' "${cidr}"
        sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
            --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" destination address=\"${cidr}\" port port=\"443\" protocol=\"tcp\" accept"
    done
    echo "  Allowed ${label} HTTPS CIDRs"
}

if [[ " ${ENABLED_BROKERS} " == *" bedrock "* ]]; then
    if [[ -n "${BEDROCK_ENDPOINT_CIDR}" ]]; then
        sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
            --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" destination address=\"${BEDROCK_ENDPOINT_CIDR}\" port port=\"443\" protocol=\"tcp\" accept"
    else
        NUM_CIDRS=$(wc -w <<< "${BEDROCK_PUBLIC_CIDRS}")
        echo "WARNING: using BEDROCK_PUBLIC_CIDRS fallback (${NUM_CIDRS} CIDRs) — this is the" >&2
        echo "  generic AWS 'AMAZON' regional range, not a Bedrock-specific allow-list (AWS" >&2
        echo "  publishes no BEDROCK-tagged entry in ip-ranges.json). It blocks non-AWS-hosted" >&2
        echo "  C2 but NOT C2 rented on AWS infrastructure. Treat this as a temporary stopgap" >&2
        echo "  only, pending a Bedrock VPC endpoint. See SecurityRemediationPlan.md, open" >&2
        echo "  question #1." >&2
        for cidr in ${BEDROCK_PUBLIC_CIDRS}; do
            sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
                --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" destination address=\"${cidr}\" port port=\"443\" protocol=\"tcp\" accept"
        done
    fi
fi

allow_https_cidrs "USAI" "${USAI_ENDPOINT_CIDRS}"
allow_https_cidrs "Codex/ChatGPT" "${CODEX_ENDPOINT_CIDRS}"
allow_https_cidrs "AWS STS" "${STS_ENDPOINT_CIDRS}"

if [[ -n "${RDS_ENDPOINT_CIDR}" ]]; then
    sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
        --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" destination address=\"${RDS_ENDPOINT_CIDR}\" port port=\"${RDS_PORT}\" protocol=\"tcp\" accept"
fi

# Catch-all reject runs last (positive priority), scoped to this subnet only —
# it never touches traffic from any other source address on this host.
sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
    --add-rich-rule="rule priority=\"32767\" family=\"ipv4\" source address=\"${SUBNET}\" reject"

sudo firewall-cmd --reload

echo ""
echo "Egress policy '${POLICY_NAME}' applied. Traffic sourced from ${SUBNET} is now"
echo "denied by default; only internal traffic, DNS, IMDS, and configured broker/RDS"
echo "destinations are allowed. No other zone, port, or subnet was modified."
echo ""
echo "Verify:"
echo "  sudo firewall-cmd --policy=${POLICY_NAME} --list-all"
echo "  podman exec litellm-proxy curl -m3 https://example.com          # should now fail"
echo "  podman exec litellm-proxy curl -m3 -X PUT http://169.254.169.254/latest/api/token \\"
echo "    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'                 # should still succeed"
