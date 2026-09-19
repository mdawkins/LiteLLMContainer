#!/bin/sh
set -eu

CERT_DIR=/etc/nginx/certs
CERT_FILE=${CERT_DIR}/proxy.crt
KEY_FILE=${CERT_DIR}/proxy.key

if [ ! -s "${CERT_FILE}" ] || [ ! -s "${KEY_FILE}" ]; then
    echo "ERROR: TLS certificate/key missing from ${CERT_DIR}." >&2
    echo "Run ./stackctl.sh tls (or ./stackctl.sh start) on the host first." >&2
    exit 1
fi

# Hand off control to Nginx.
exec nginx -g "daemon off;"
