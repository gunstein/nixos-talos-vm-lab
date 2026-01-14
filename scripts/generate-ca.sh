#!/usr/bin/env bash
# Generate a self-signed CA and wildcard certificate for *.lab.local
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CERT_DIR="${1:-/etc/nixos/talos-host/certs}"
DOMAIN="lab.local"

mkdir -p "$CERT_DIR"

# Check if CA already exists
if [[ -f "${CERT_DIR}/ca.crt" && -f "${CERT_DIR}/ca.key" ]]; then
  log "CA already exists in ${CERT_DIR}"
  exit 0
fi

log "Generating CA and wildcard certificate for *.${DOMAIN}"

# Generate CA private key
openssl genrsa -out "${CERT_DIR}/ca.key" 4096

# Generate CA certificate (valid for 10 years)
openssl req -x509 -new -nodes \
  -key "${CERT_DIR}/ca.key" \
  -sha256 \
  -days 3650 \
  -out "${CERT_DIR}/ca.crt" \
  -subj "/CN=Talos Lab CA/O=Lab/C=NO"

# Generate server private key
openssl genrsa -out "${CERT_DIR}/server.key" 2048

# Generate CSR config with SANs
cat > "${CERT_DIR}/server.cnf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = *.${DOMAIN}
O = Lab
C = NO

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.${DOMAIN}
DNS.2 = ${DOMAIN}
DNS.3 = demo.${DOMAIN}
DNS.4 = grafana.${DOMAIN}
DNS.5 = prometheus.${DOMAIN}
DNS.6 = traefik.${DOMAIN}
EOF

# Generate CSR
openssl req -new \
  -key "${CERT_DIR}/server.key" \
  -out "${CERT_DIR}/server.csr" \
  -config "${CERT_DIR}/server.cnf"

# Sign certificate with CA (valid for 1 year)
openssl x509 -req \
  -in "${CERT_DIR}/server.csr" \
  -CA "${CERT_DIR}/ca.crt" \
  -CAkey "${CERT_DIR}/ca.key" \
  -CAcreateserial \
  -out "${CERT_DIR}/server.crt" \
  -days 365 \
  -sha256 \
  -extensions req_ext \
  -extfile "${CERT_DIR}/server.cnf"

# Clean up CSR
rm -f "${CERT_DIR}/server.csr" "${CERT_DIR}/server.cnf"

log "CA and server certificate generated in ${CERT_DIR}"
log ""
log "To trust the CA on your machine, import:"
log "  ${CERT_DIR}/ca.crt"
log ""
log "Files generated:"
log "  ${CERT_DIR}/ca.crt      - CA certificate (import to browser)"
log "  ${CERT_DIR}/ca.key      - CA private key (keep safe)"
log "  ${CERT_DIR}/server.crt  - Server certificate"
log "  ${CERT_DIR}/server.key  - Server private key"
