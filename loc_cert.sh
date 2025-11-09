#!/usr/bin/env bash
set -euo pipefail

# loc_cert.sh
# Create a local Root CA with OpenSSL and import it into Snap Chromium/Firefox NSS stores.
# Usage: sudo ./loc_cert.sh
#
# - Creates /etc/local-ca/local-rootCA.{key,pem} if missing.
# - Sets strict permissions.
# - Imports the root CA into the invoking user's NSS (Chromium/Firefox Snap) without prompts.
#
# Notes:
# * Run with sudo. We'll import into $SUDO_USER (or $USER if not set).
# * Close all browsers before running; reopen after.
# * If you later want to remove the CA, just delete /etc/local-ca and remove the cert from NSS.
#
# This script does NOT touch mkcert at all.

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Please run as root: sudo ./loc_cert.sh"
  exit 1
fi

CA_DIR="/etc/local-ca"
NGX_CERT_DIR="/etc/nginx/certs"
ROOT_PEM="${CA_DIR}/local-rootCA.pem"
ROOT_KEY="${CA_DIR}/local-rootCA.key"

mkdir -p "$CA_DIR" "$NGX_CERT_DIR"

if [ ! -f "$ROOT_KEY" ] || [ ! -f "$ROOT_PEM" ]; then
  echo "[*] Creating local Root CA in ${CA_DIR} ..."
  openssl genrsa -out "$ROOT_KEY" 4096
  openssl req -x509 -new -nodes -key "$ROOT_KEY" -sha256 -days 3650 \
    -out "$ROOT_PEM" -subj "/C=XX/O=Local Dev CA/CN=Local Dev Root"
  chmod 600 "$ROOT_KEY"
  chmod 644 "$ROOT_PEM"
  echo "[OK] Root CA created: $ROOT_PEM"
else
  echo "[=] Root CA already exists: $ROOT_PEM"
fi

# Decide which user's NSS to import into
TARGET_USER="${SUDO_USER:-$USER}"
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "[!] Cannot resolve target user for NSS import."
  exit 0
fi
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  echo "[!] Home directory for ${TARGET_USER} not found; skipping NSS import."
  exit 0
fi

echo "[*] Importing root CA into NSS stores for user: ${TARGET_USER}"

# Helper to run as target user
run_as_user() {
  sudo -u "$TARGET_USER" -- "$@"
}

# Chromium (Snap) NSS
CH_DB="${USER_HOME}/snap/chromium/current/.pki/nssdb"
run_as_user mkdir -p "$CH_DB"
run_as_user certutil -N -d "sql:${CH_DB}" --empty-password 2>/dev/null || true
PWDFILE=$(mktemp); printf '\n' | tee "$PWDFILE" >/dev/null
run_as_user certutil -A -d "sql:${CH_DB}" -f "$PWDFILE" -n "Local Dev Root" -t "C,," -i "$ROOT_PEM" || true
run_as_user certutil -L -d "sql:${CH_DB}" | grep -qi "Local Dev Root" && echo "[OK] Imported into Chromium NSS" || echo "[!] Chromium NSS: entry not visible"
rm -f "$PWDFILE"

# Firefox (Snap) NSS (requires at least one launch to create profile)
FF_PROFILE_DIR=$(run_as_user bash -lc 'ls -d "$HOME"/snap/firefox/common/.mozilla/firefox/*.default* 2>/dev/null | head -n1')
if [ -n "$FF_PROFILE_DIR" ]; then
  run_as_user certutil -N -d "sql:${FF_PROFILE_DIR}" --empty-password 2>/dev/null || true
  PWDFILE=$(mktemp); printf '\n' | tee "$PWDFILE" >/dev/null
  run_as_user certutil -A -d "sql:${FF_PROFILE_DIR}" -f "$PWDFILE" -n "Local Dev Root" -t "C,," -i "$ROOT_PEM" || true
  run_as_user certutil -L -d "sql:${FF_PROFILE_DIR}" | grep -qi "Local Dev Root" && echo "[OK] Imported into Firefox NSS" || echo "[!] Firefox NSS: entry not visible"
  rm -f "$PWDFILE"
else
  echo "[i] Firefox profile not found — launch Firefox once and re-run this script to import."
fi

echo "[DONE] Local Root CA ready. Reopen browsers to apply trust."
