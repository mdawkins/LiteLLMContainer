#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "LLM-Lite Container Stack - Prerequisites"
echo "============================================"

# --- 1. Verify Environment Variables ---
echo ""
echo "[1/4] Checking environment variables..."

REQUIRED_VARS=("HOME")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "  ERROR: $var is not set."
        exit 1
    fi
done

CONTAINERS="${CONTAINERS:-$HOME/Build/Containers}"
VOLUMES="${VOLUMES:-$HOME/Build/Volumes}"

echo "  CONTAINERS=$CONTAINERS"
echo "  VOLUMES=$VOLUMES"

# --- 2. Create Persistent Volume Directories ---
echo ""
echo "[2/4] Creating persistent volume directories..."

mkdir -p "${VOLUMES}/litellm_pgvol/data"
echo "  Created: ${VOLUMES}/litellm_pgvol/data"

# --- 3. Ensure Podman Network Exists ---
echo ""
echo "[3/4] Ensuring podman network exists..."

NETWORK_NAME="internal_net"
if podman network exists "$NETWORK_NAME" 2>/dev/null; then
    echo "  Network '$NETWORK_NAME' already exists."
else
    podman network create "$NETWORK_NAME"
    echo "  Created network: $NETWORK_NAME"
fi

# --- 4. Verify Container Images Are Pullable ---
echo ""
echo "[4/4] Verifying container image availability..."

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
echo "  podman compose -f ${CONTAINERS}/LLMLiteContainer/compose-litellm.yaml up -d"
echo "============================================"
