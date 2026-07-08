#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo "LiteLLM Container Stack - Prerequisites"
echo "============================================"

# --- 1. Verify Environment Variables ---
echo ""
echo "[1/8] Checking environment variables..."

REQUIRED_VARS=("HOME")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "  ERROR: $var is not set."
        exit 1
    fi
done

CONTAINERS="${CONTAINERS:-/Build/Containers}"
VOLUMES="${VOLUMES:-/Build/Volumes}"

echo "  CONTAINERS=$CONTAINERS"
echo "  VOLUMES=$VOLUMES"

# --- 2. Rootless Podman — unprivileged ports and linger ---
echo ""
echo "[2/8] Configuring rootless podman (ports 80/443, linger)..."

SYSCTL_CONF="/etc/sysctl.d/99-podman-rootless.conf"
if [[ ! -f "${SYSCTL_CONF}" ]] || ! grep -q "ip_unprivileged_port_start = 80" "${SYSCTL_CONF}" 2>/dev/null; then
    echo "net.ipv4.ip_unprivileged_port_start = 80" | sudo tee "${SYSCTL_CONF}" > /dev/null
    sudo sysctl --system > /dev/null
    echo "  Set net.ipv4.ip_unprivileged_port_start = 80"
else
    echo "  Unprivileged port start already set to 80."
fi

CURRENT_USER="${SUDO_USER:-$(whoami)}"
if ! loginctl show-user "${CURRENT_USER}" 2>/dev/null | grep -q "Linger=yes"; then
    sudo loginctl enable-linger "${CURRENT_USER}"
    echo "  Enabled linger for ${CURRENT_USER}."
else
    echo "  Linger already enabled for ${CURRENT_USER}."
fi

# --- 3. Container log rotation ---
echo ""
echo "[3/8] Configuring container log rotation..."

CONTAINERS_CONF="/etc/containers/containers.conf"
if [[ ! -f "${CONTAINERS_CONF}" ]] || ! grep -q "log_size_max" "${CONTAINERS_CONF}" 2>/dev/null; then
    printf '[containers]\nlog_driver = "k8s-file"\nlog_size_max = 52428800\n' | sudo tee "${CONTAINERS_CONF}" > /dev/null
    sudo chmod 644 "${CONTAINERS_CONF}"
    echo "  Written: ${CONTAINERS_CONF} (50MB per-container log cap)"
else
    sudo chmod 644 "${CONTAINERS_CONF}"
    echo "  Already configured."
fi

# --- 4. Create Persistent Volume Directories ---
echo ""
echo "[4/8] Creating persistent volume directories..."

mkdir -p "${VOLUMES}/litellm_pgvol"
echo "  Created: ${VOLUMES}/litellm_pgvol"

# Postgres runs as UID 999 inside the container. Under rootless podman the host
# dir must be owned by that UID within the user namespace — podman unshare handles
# the subUID mapping transparently.
# Container init runs as root (UID 0 in namespace = mdawkins on host).
# chown 0:0 + chmod 755 lets the entrypoint create subdirs and chown them to postgres (999).
podman unshare chown 0:0 "${VOLUMES}/litellm_pgvol"
chmod 755 "${VOLUMES}/litellm_pgvol"
echo "  Volume ownership set for rootless container init"

# --- 3. Ensure Podman Network Exists ---
echo ""
echo "[5/8] Ensuring podman network exists..."

NETWORK_NAME="internal_net"
if podman network exists "$NETWORK_NAME" 2>/dev/null; then
    echo "  Network '$NETWORK_NAME' already exists."
else
    podman network create "$NETWORK_NAME"
    echo "  Created network: $NETWORK_NAME"
fi

# --- 4. Generate .env from IMDS (EC2 IAM role credentials) ---
echo ""
echo "[6/8] Generating .env and making scripts executable..."

chmod +x "${SCRIPT_DIR}/gen-env.sh" \
         "${SCRIPT_DIR}/create-ai-user.sh" \
         "${SCRIPT_DIR}/check-ai-user.sh" \
         "${SCRIPT_DIR}/revoke-ai-user.sh"
"${SCRIPT_DIR}/gen-env.sh"

# --- 5. Install systemd boot unit ---
echo ""
echo "[7/8] Installing litellm-stack.service systemd unit..."

UNIT_SRC="${SCRIPT_DIR}/litellm-stack.service"
UNIT_DST="/etc/systemd/system/litellm-stack.service"
CURRENT_UID=$(id -u "${CURRENT_USER}")

# Substitute $USER and __UID__ placeholders — systemd does not do shell expansion
UNIT_TMP=$(mktemp)
sed -e "s/\$USER/${CURRENT_USER}/g" \
    -e "s/__UID__/${CURRENT_UID}/g" \
    "${UNIT_SRC}" > "${UNIT_TMP}"

if [[ ! -f "${UNIT_DST}" ]] || ! diff -q "${UNIT_TMP}" "${UNIT_DST}" &>/dev/null; then
    sudo cp "${UNIT_TMP}" "${UNIT_DST}"
    sudo systemctl daemon-reload
    echo "  Installed: ${UNIT_DST} (User=${CURRENT_USER}, UID=${CURRENT_UID})"
else
    echo "  Already up to date."
fi
rm -f "${UNIT_TMP}"

if ! systemctl is-enabled litellm-stack.service &>/dev/null; then
    sudo systemctl enable litellm-stack.service
    echo "  Enabled for boot."
else
    echo "  Already enabled."
fi

# --- 6. Verify Container Images Are Pullable ---
echo ""
echo "[8/8] Verifying container image availability..."

IMAGES=(
    "postgres:18"
    "ghcr.io/berriai/litellm:main-latest"
    "nginx:alpine"
)

for img in "${IMAGES[@]}"; do
    echo "  Checking: $img"
    if ! podman image exists "$img" 2>/dev/null; then
        echo "  Pulling: $img"
        podman pull "$img"
    else
        echo "    (already present)"
    fi
done

echo ""
echo "============================================"
echo "All prerequisites satisfied."
echo "You can now run:"
echo "  podman-compose -f ${SCRIPT_DIR}/compose-litellm.yaml build"
echo "  podman-compose -f ${SCRIPT_DIR}/compose-litellm.yaml up -d"
echo ""
echo "The stack will auto-start on boot via litellm-stack.service."
echo "AWS credentials are fetched from IMDS at runtime — no manual refresh needed."
echo "============================================"
