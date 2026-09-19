#!/bin/sh
set -eu

# If no IP is passed during 'docker run', default to 127.0.0.1.
TARGET_IP=${PROXY_IP:-127.0.0.1}
CERT_DIR=/etc/nginx/certs
CERT_FILE=${CERT_DIR}/proxy.crt
KEY_FILE=${CERT_DIR}/proxy.key
# Renew a self-signed certificate when it has less than 30 days remaining.
RENEW_SECONDS=${CERT_RENEW_SECONDS:-2592000}

mkdir -p "${CERT_DIR}"

certificate_is_reusable() {
    [ -s "${CERT_FILE}" ] && [ -s "${KEY_FILE}" ] || return 1

    # Check parsing, expiry, and the SAN used by clients to reach this proxy.
    openssl x509 -in "${CERT_FILE}" -noout >/dev/null 2>&1 || return 1
    openssl x509 -in "${CERT_FILE}" -checkend "${RENEW_SECONDS}" -noout >/dev/null 2>&1 || return 1
    openssl x509 -in "${CERT_FILE}" -checkip "${TARGET_IP}" -noout >/dev/null 2>&1 || return 1

    # Ensure the private key belongs to the certificate. Both are generated as
    # RSA files, so modulus comparison avoids temporary files and extra tooling.
    cert_modulus=$(openssl x509 -in "${CERT_FILE}" -noout -modulus 2>/dev/null) || return 1
    key_modulus=$(openssl rsa -in "${KEY_FILE}" -noout -modulus 2>/dev/null) || return 1
    [ "${cert_modulus}" = "${key_modulus}" ]
}

if certificate_is_reusable; then
    echo "Reusing existing SSL certificate for IP: ${TARGET_IP}"
else
    echo "Generating SSL certificate for IP: ${TARGET_IP}"
    temp_dir=$(mktemp -d "${CERT_DIR}/.proxy-cert.XXXXXX")
    cleanup() { rm -rf "${temp_dir}"; }
    trap cleanup EXIT INT TERM
    umask 077
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${temp_dir}/proxy.key" \
        -out "${temp_dir}/proxy.crt" \
        -subj "/CN=${TARGET_IP}" \
        -addext "subjectAltName=IP:${TARGET_IP}"
    chmod 600 "${temp_dir}/proxy.key"
    chmod 644 "${temp_dir}/proxy.crt"
    # Keep an existing pair until both replacement files are complete.
    mv -f "${temp_dir}/proxy.key" "${KEY_FILE}"
    mv -f "${temp_dir}/proxy.crt" "${CERT_FILE}"
    cleanup
    trap - EXIT INT TERM
fi

# Hand off control to Nginx.
exec nginx -g "daemon off;"
