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
sudo bash new_host.sh sandbox.lv /home/human/dev/lv/sandbox/public
sudo bash new_host.sh adminer.lv  /home/human/dev/app/adminer/public
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

## Detailed steps (same flow as the scripts)

> These are the exact commands used internally by the scripts. You can run them manually if desired.

### 0) Hosts (IPv4 only)

```bash
sudo sed -i '/sandbox\.lv/d;/adminer\.lv/d' /etc/hosts
echo '127.0.0.1 sandbox.lv www.sandbox.lv'   | sudo tee -a /etc/hosts
echo '127.0.0.1 adminer.lv www.adminer.lv'   | sudo tee -a /etc/hosts
```

### 1) Create local Root CA

```bash
sudo mkdir -p /etc/local-ca /etc/nginx/certs
cd /etc/local-ca
sudo openssl genrsa -out local-rootCA.key 4096
sudo openssl req -x509 -new -nodes -key local-rootCA.key -sha256 -days 3650 \
  -out local-rootCA.pem -subj "/C=XX/O=Local Dev CA/CN=Local Dev Root"
sudo chmod 600 local-rootCA.key
sudo chmod 644 local-rootCA.pem
```

### 2) Import root CA into Snap Chromium/Firefox (NSS)

```bash
ROOT="/etc/local-ca/local-rootCA.pem"

# Chromium (Snap)
DB="$HOME/snap/chromium/current/.pki/nssdb"
mkdir -p "$DB"; certutil -N -d "sql:$DB" --empty-password 2>/dev/null || true
certutil -A -d "sql:$DB" -n "Local Dev Root" -t "C,," -i "$ROOT"

# Firefox (Snap) — запусти FF один раз, чтобы профиль появился
FFP=$(ls -d $HOME/snap/firefox/common/.mozilla/firefox/*.default* 2>/dev/null | head -n1)
[ -n "$FFP" ] && certutil -A -d "sql:$FFP" -n "Local Dev Root" -t "C,," -i "$ROOT"
```

### 3) Issue domain certificates (example: `sandbox.lv`, `adminer.lv`)

```bash
DIR=/etc/nginx/certs

# sandbox.lv
sudo openssl genrsa -out $DIR/sandbox.lv.key 2048
sudo openssl req -new -key $DIR/sandbox.lv.key -out $DIR/sandbox.lv.csr -subj "/CN=sandbox.lv"
sudo tee $DIR/sandbox.lv.ext >/dev/null <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = sandbox.lv
DNS.2 = www.sandbox.lv
EOF
sudo openssl x509 -req -in $DIR/sandbox.lv.csr -CA /etc/local-ca/local-rootCA.pem -CAkey /etc/local-ca/local-rootCA.key -CAcreateserial -out $DIR/sandbox.lv.crt -days 825 -sha256 -extfile $DIR/sandbox.lv.ext
sudo bash -c 'cat /etc/nginx/certs/sandbox.lv.crt /etc/local-ca/local-rootCA.pem > /etc/nginx/certs/sandbox.lv-fullchain.crt'
sudo chmod 600 $DIR/sandbox.lv.key
sudo chmod 644 $DIR/sandbox.lv.crt $DIR/sandbox.lv-fullchain.crt

# adminer.lv
sudo openssl genrsa -out $DIR/adminer.lv.key 2048
sudo openssl req -new -key $DIR/adminer.lv.key -out $DIR/adminer.lv.csr -subj "/CN=adminer.lv"
sudo tee $DIR/adminer.lv.ext >/dev/null <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = adminer.lv
DNS.2 = www.adminer.lv
EOF
sudo openssl x509 -req -in $DIR/adminer.lv.csr -CA /etc/local-ca/local-rootCA.pem -CAkey /etc/local-ca/local-rootCA.key -CAcreateserial -out $DIR/adminer.lv.crt -days 825 -sha256 -extfile $DIR/adminer.lv.ext
sudo bash -c 'cat /etc/nginx/certs/adminer.lv.crt /etc/local-ca/local-rootCA.pem > /etc/nginx/certs/adminer.lv-fullchain.crt'
sudo chmod 600 $DIR/adminer.lv.key
sudo chmod 644 $DIR/adminer.lv.crt $DIR/adminer.lv-fullchain.crt
```

### 4) Nginx TLS vhosts

```bash
# sandbox.lv
sudo tee /etc/nginx/sites-available/sandbox.lv.conf >/dev/null <<'NGINX'
server {
  listen 80;
  server_name sandbox.lv www.sandbox.lv;
  return 301 https://$host$request_uri;
}
server {
  listen 443 ssl;
  http2 on;
  server_name sandbox.lv www.sandbox.lv;

  ssl_certificate     /etc/nginx/certs/sandbox.lv-fullchain.crt;
  ssl_certificate_key /etc/nginx/certs/sandbox.lv.key;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!MD5;

  root /home/human/dev/lv/sandbox/public;
  index index.php index.html;

  location / { try_files $uri $uri/ /index.php?$query_string; }
  location ~ \.php$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/run/php/php8.4-fpm.sock; }
  location ~ /\. { deny all; }
}
NGINX
sudo ln -sf /etc/nginx/sites-available/sandbox.lv.conf /etc/nginx/sites-enabled/sandbox.lv.conf

# adminer.lv
sudo tee /etc/nginx/sites-available/adminer.lv.conf >/dev/null <<'NGINX'
server {
  listen 80;
  server_name adminer.lv www.adminer.lv;
  return 301 https://$host$request_uri;
}
server {
  listen 443 ssl;
  http2 on;
  server_name adminer.lv www.adminer.lv;

  ssl_certificate     /etc/nginx/certs/adminer.lv-fullchain.crt;
  ssl_certificate_key /etc/nginx/certs/adminer.lv.key;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!MD5;

  root /home/human/dev/app/adminer/public;
  index index.php;

  location / { try_files $uri $uri/ /index.php?$query_string; }
  location ~ \.php$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/run/php/php8.4-fpm.sock; }
  location ~ /\. { deny all; }
}
NGINX
sudo ln -sf /etc/nginx/sites-available/adminer.lv.conf /etc/nginx/sites-enabled/adminer.lv.conf

# apply
sudo nginx -t && sudo systemctl reload nginx
```

### 5) Verify

```bash
# SANs should list your domain names
openssl s_client -connect 127.0.0.1:443 -servername sandbox.lv  </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
openssl s_client -connect 127.0.0.1:443 -servername adminer.lv </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
```

---

## Troubleshooting

- **Browser still shows “Not secure”**  
  Re-run `sudo bash loc_cert.sh` (with browsers closed), then fully restart browsers.  
  Clear HSTS/cache for the domain if you visited it before with different settings:
  - Chrome/Chromium: `chrome://net-internals/#hsts` → **Delete domain security policies**
  - Firefox: History → find the domain → **Forget about this site**

- **`nginx -t` fails with missing `*.conf`**  
  Remove stale includes (e.g., `adminer.dev.conf`) and ensure the `*.lv.conf` files are symlinked in `sites-enabled`.

- **Port 443 not listening**  
  `sudo ss -tlpn | grep ':443'` — if empty, check your TLS server blocks, certificate paths, and `nginx -t` output.

- **Laravel shows 500**  
  The TLS config is fine; fix the app:  
  ```bash
  cd /path/to/laravel
  php artisan key:generate
  php artisan config:clear
  php artisan route:clear
  php artisan view:clear
  php artisan cache:clear
  tail -n 100 storage/logs/laravel.log
  ```

- **Adminer 404**  
  Ensure `index.php` exists in the site’s `public` directory (copy your `adminer-*.php` to `public/index.php`).

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
