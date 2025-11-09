#!/usr/bin/env bash
set -euo pipefail

# new_host.sh
# Create a new HTTPS vhost for Nginx using the local OpenSSL Root CA.
# - Prompts for domain (or accepts as $1) and webroot (or $2).
# - Ensures domain is not already configured in hosts or Nginx.
# - Issues a per-domain certificate with SANs (domain + www).
# - Writes an Nginx vhost (80 -> 443 redirect + TLS server) and reloads.
#
# Usage:
#   sudo ./new_host.sh                 # interactive prompts
#   sudo ./new_host.sh test.lv /path/to/project/public
#
# Requirements:
#   - Run with sudo (writes to /etc/*)
#   - Local root CA installed via loc_cert.sh (files in /etc/local-ca)
#   - PHP-FPM running (we'll autodetect a /run/php/php*-fpm.sock)
#
# This script does NOT touch mkcert.

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Please run as root: sudo ./new_host.sh <domain> <webroot>"
  exit 1
fi

DOMAIN="${1:-}"
if [ -z "${DOMAIN}" ]; then
  read -rp "Enter domain (e.g., test.lv): " DOMAIN
fi
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')
if ! [[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]]; then
  echo "[!] Invalid domain format."; exit 1
fi
WWW="www.${DOMAIN}"

WEBROOT="${2:-}"
if [ -z "${WEBROOT}" ]; then
  read -rp "Enter absolute webroot path (e.g., /home/you/project/public): " WEBROOT
fi
if [ ! -d "$WEBROOT" ]; then
  echo "[!] Webroot does not exist: $WEBROOT"; exit 1
fi

# Check local CA exists
CA_DIR="/etc/local-ca"
ROOT_PEM="${CA_DIR}/local-rootCA.pem"
ROOT_KEY="${CA_DIR}/local-rootCA.key"
if [ ! -f "$ROOT_PEM" ] || [ ! -f "$ROOT_KEY" ]; then
  echo "[!] Local root CA not found in ${CA_DIR}. Run: sudo ./loc_cert.sh"
  exit 1
fi

# Ensure domain not already configured
if grep -qE "[[:space:]]${DOMAIN}($|[[:space:]])" /etc/hosts 2>/dev/null; then
  echo "[!] /etc/hosts already has an entry for ${DOMAIN}. Aborting to avoid conflicts."
  exit 1
fi

if grep -R -qE "server_name\s+.*\b${DOMAIN}\b" /etc/nginx 2>/dev/null; then
  echo "[!] Nginx configuration already references ${DOMAIN}. Aborting."
  exit 1
fi

# Append hosts (IPv4 only — keeps things simple)
echo "127.0.0.1 ${DOMAIN} ${WWW}" | tee -a /etc/hosts >/dev/null

# Issue certificate
CERT_DIR="/etc/nginx/certs"
mkdir -p "$CERT_DIR"

echo "[*] Issuing certificate for ${DOMAIN} ..."
openssl genrsa -out "${CERT_DIR}/${DOMAIN}.key" 2048
openssl req -new -key "${CERT_DIR}/${DOMAIN}.key" -out "${CERT_DIR}/${DOMAIN}.csr" -subj "/CN=${DOMAIN}"

cat > "${CERT_DIR}/${DOMAIN}.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = ${WWW}
EOF

openssl x509 -req -in "${CERT_DIR}/${DOMAIN}.csr" \
  -CA "${ROOT_PEM}" -CAkey "${ROOT_KEY}" -CAcreateserial \
  -out "${CERT_DIR}/${DOMAIN}.crt" -days 825 -sha256 -extfile "${CERT_DIR}/${DOMAIN}.ext"

bash -c "cat '${CERT_DIR}/${DOMAIN}.crt' '${ROOT_PEM}' > '${CERT_DIR}/${DOMAIN}-fullchain.crt'"

chmod 600 "${CERT_DIR}/${DOMAIN}.key"
chmod 644 "${CERT_DIR}/${DOMAIN}.crt" "${CERT_DIR}/${DOMAIN}-fullchain.crt"

# Find PHP-FPM socket
PHP_SOCK="$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1 || true)"
if [ -z "$PHP_SOCK" ]; then
  echo "[!] PHP-FPM socket not found in /run/php/. Is php-fpm installed and running?"
  exit 1
fi

# Write Nginx vhost
AVAIL="/etc/nginx/sites-available/${DOMAIN}.conf"
ENAB="/etc/nginx/sites-enabled/${DOMAIN}.conf"

cat > "$AVAIL" <<NGINX
server {
  listen 80;
  server_name ${DOMAIN} ${WWW};
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl;
  http2 on;
  server_name ${DOMAIN} ${WWW};

  ssl_certificate     ${CERT_DIR}/${DOMAIN}-fullchain.crt;
  ssl_certificate_key ${CERT_DIR}/${DOMAIN}.key;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!MD5;

  root ${WEBROOT};
  index index.php index.html;

  location / { try_files \$uri \$uri/ /index.php?\$query_string; }
  location ~ \.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:${PHP_SOCK}; }
  location ~ /\. { deny all; }
}
NGINX

ln -sf "$AVAIL" "$ENAB"

# Test and reload
nginx -t
systemctl reload nginx

# Verify
echo "[*] Verifying served certificate for ${DOMAIN} ..."
OUT="$(openssl s_client -connect 127.0.0.1:443 -servername "${DOMAIN}" </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName || true)"
echo "$OUT"
echo "$OUT" | grep -q "DNS:${DOMAIN}" && echo "[OK] HTTPS is ready: https://${DOMAIN}" || {
  echo "[WARN] Could not verify SAN for ${DOMAIN}. Check vhost and certificate paths."; exit 1;
}
