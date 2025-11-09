# Local HTTPS for Nginx on Ubuntu (No mkcert)

Tools and scripts to set up **trusted HTTPS** for local PHP sites on **Ubuntu** using your **own OpenSSL-based Certificate Authority (CA)**.  
No mkcert required. Works great with **Nginx + PHP‑FPM** and Snap browsers (Chromium/Firefox).

## What you get

- `loc_cert.sh` — creates a local Root CA in `/etc/local-ca` and imports it into **Chromium/Firefox (Snap) NSS** trust stores.
- `new_host.sh` — interactively (or via args) adds a **new HTTPS virtual host**:
  - appends the host to `/etc/hosts` (IPv4 only)
  - issues a per-domain certificate with SANs (domain + `www.`)
  - writes an Nginx vhost (HTTP → HTTPS redirect + TLS server)
  - reloads Nginx

Tested on Ubuntu with:
- Nginx 1.28.x
- PHP‑FPM 8.4 (socket: `/run/php/php8.4-fpm.sock`)
- Snap Chromium/Firefox

> **Note on TLDs:** Avoid `.dev` for local HTTP — it’s HSTS-preloaded (HTTPS-only). Use `.lv`, `.test`, or `.localhost` for local development. These scripts assume domains like `sandbox.lv`, `adminer.lv`, etc.

---

## Prerequisites (Ubuntu)

```bash
sudo apt update
sudo apt install -y nginx php-fpm openssl libnss3-tools
```

- Make sure `php-fpm` is running (`systemctl status php8.4-fpm`).
- Ensure your webroots exist (e.g., `/home/you/project/public`).

---

## Quick Start

1) **Create your local CA and import trust (one-time):**
```bash
sudo bash loc_cert.sh
```

2) **Add a new HTTPS site:**
```bash
# Interactive
sudo bash new_host.sh

# Or via arguments
sudo bash new_host.sh adminer.lv  /home/usr/app/adminer/public
```

3) **Open in browser:**
- `https://sandbox.lv`
- `https://adminer.lv`

If the browser still warns about trust, close all browser windows and reopen. For Snap Chromium/Firefox, `loc_cert.sh` imports the root CA into NSS automatically; if you ran browsers during import, repeat the import and restart browsers.

---

## How it works (overview)

- `loc_cert.sh` creates `/etc/local-ca/local-rootCA.{key,pem}` and imports the **Local Dev Root** certificate into your local Snap **NSS** stores so browsers trust certs signed by this CA.
- `new_host.sh`:
  - appends `127.0.0.1 <domain> www.<domain>` to `/etc/hosts`
  - issues a leaf cert + `fullchain`:
    - `<domain>.key`, `<domain>.crt`, `<domain>-fullchain.crt` in `/etc/nginx/certs`
  - writes `/etc/nginx/sites-available/<domain>.conf` and enables it via `sites-enabled`
  - reloads Nginx and verifies the SAN via `openssl s_client`

This keeps things reproducible and avoids cross-site certificate mixups.

---

## Uninstall / Reset

- Remove a site:
  ```bash
  sudo sed -i '/\smyhost\.lv$/d;/\swww\.myhost\.lv$/d' /etc/hosts
  sudo rm -f /etc/nginx/sites-enabled/myhost.lv.conf /etc/nginx/sites-available/myhost.lv.conf
  sudo rm -f /etc/nginx/certs/myhost.lv.*
  sudo nginx -t && sudo systemctl reload nginx
  ```

- Remove local CA (be careful — all issued certs will break):
  ```bash
  sudo rm -rf /etc/local-ca
  # Remove from NSS:
  # Chromium:
  certutil -D -d sql:$HOME/snap/chromium/current/.pki/nssdb -n "Local Dev Root"
  # Firefox:
  FFP=$(ls -d $HOME/snap/firefox/common/.mozilla/firefox/*.default* 2>/dev/null | head -n1)
  [ -n "$FFP" ] && certutil -D -d sql:$FFP -n "Local Dev Root"
  ```

---

## License

MIT

---

## Directory layout (after adding a couple of hosts)

```
/etc/local-ca/
  ├── local-rootCA.key
  └── local-rootCA.pem
/etc/nginx/certs/
  ├── sandbox.lv.key
  ├── sandbox.lv.crt
  ├── sandbox.lv-fullchain.crt
  ├── adminer.lv.key
  ├── adminer.lv.crt
  └── adminer.lv-fullchain.crt
/etc/nginx/sites-available/
  ├── sandbox.lv.conf
  └── adminer.lv.conf
/etc/nginx/sites-enabled/
  ├── sandbox.lv.conf -> ../sites-available/sandbox.lv.conf
  └── adminer.lv.conf -> ../sites-available/adminer.lv.conf
```

Happy hacking! 🚀
