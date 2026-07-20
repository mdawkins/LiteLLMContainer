#!/usr/bin/env bash
# Restricts outbound traffic from the litellm-proxy container's bridge subnet
# (internal_net) to only DNS, the EC2 IMDS, and Amazon Bedrock — the "killer
# control" for a compromised dependency trying to call home to a C2 server.
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
# Option B (fallback): public Bedrock IP ranges for the target region, from
# https://ip-ranges.amazonaws.com/ip-ranges.json (service: BEDROCK). Review
# and re-run periodically since these can change.
BEDROCK_PUBLIC_CIDRS="${BEDROCK_PUBLIC_CIDRS:-}"       # space-separated CIDRs

# --- Amazon RDS (optional) — set only if litellm-proxy has been switched to
# an RDS-backed DATABASE_URL (see rds-postgres.yaml). Traffic to the local
# litellm-db container never leaves the host and doesn't need this; traffic
# to RDS routes off-host and would otherwise hit the catch-all reject below.
RDS_ENDPOINT_CIDR="${RDS_ENDPOINT_CIDR:-}"             # e.g. 10.0.6.20/32
RDS_PORT="${RDS_PORT:-5432}"

if [[ -z "${BEDROCK_ENDPOINT_CIDR}" && -z "${BEDROCK_PUBLIC_CIDRS}" ]]; then
    echo "ERROR: set BEDROCK_ENDPOINT_CIDR or BEDROCK_PUBLIC_CIDRS before running." >&2
    echo "  This is the open question for the AWS architects (SecurityRemediationPlan.md)." >&2
    echo "  Example: BEDROCK_ENDPOINT_CIDR=10.0.5.10/32 ./harden-egress.sh" >&2
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

# Allow rules run first (negative priority). DNS is required to resolve
# Bedrock/STS/IMDS hostnames; IMDS and Bedrock are the only other allowed
# destinations.
sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
    --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" port port=\"53\" protocol=\"udp\" accept"
sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
    --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" port port=\"53\" protocol=\"tcp\" accept"
sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
    --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" destination address=\"169.254.169.254/32\" accept"

if [[ -n "${BEDROCK_ENDPOINT_CIDR}" ]]; then
    sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
        --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" destination address=\"${BEDROCK_ENDPOINT_CIDR}\" accept"
else
    for cidr in ${BEDROCK_PUBLIC_CIDRS}; do
        sudo firewall-cmd --permanent --policy="${POLICY_NAME}" \
            --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" source address=\"${SUBNET}\" destination address=\"${cidr}\" accept"
    done
fi

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
echo "denied by default; only DNS, IMDS, and the configured Bedrock destination(s)"
echo "are allowed. No other zone, port, or subnet on this host was modified."
echo ""
echo "Verify:"
echo "  sudo firewall-cmd --policy=${POLICY_NAME} --list-all"
echo "  podman exec litellm-proxy curl -m3 https://example.com          # should now fail"
echo "  podman exec litellm-proxy curl -m3 -X PUT http://169.254.169.254/latest/api/token \\"
echo "    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'                 # should still succeed"
