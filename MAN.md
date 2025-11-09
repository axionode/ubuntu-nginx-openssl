# Local HTTPS for Nginx on Ubuntu (No mkcert) — Step‑by‑Step Guide

This guide shows how to enable **trusted HTTPS** for your local PHP sites on Ubuntu using **your own local Certificate Authority (CA) with OpenSSL** — no mkcert, no magic. It’s designed to be **predictable, minimal, and reproducible**. You’ll end up with two local domains:

- `https://sandbox.lv` → your Laravel project
- `https://adminer.lv` → your Adminer instance

> **Why `.lv` and not `.dev`?**  
> Modern browsers preload the entire `.dev` TLD with **HSTS** (HTTPS-only). If you try to use `adminer.dev` over HTTP, the browser will force HTTPS even if your server is not ready — leading to confusing errors. Staying on `.lv` avoids that gotcha for local development.

Everything below is copy‑pasteable. **Do not change the bash blocks** — they are tested as-is. Explanations are provided around them.

---

## 0) Prerequisites (run once)

Ensure both local domains resolve to **IPv4 (127.0.0.1)** — this keeps things simple and avoids IPv6/SNI surprises:

```bash
sudo sed -i '/sandbox\.lv/d;/adminer\.lv/d' /etc/hosts
echo '127.0.0.1 sandbox.lv www.sandbox.lv'   | sudo tee -a /etc/hosts
echo '127.0.0.1 adminer.lv www.adminer.lv'   | sudo tee -a /etc/hosts
```

**What this does**
- Removes any previous `sandbox.lv` / `adminer.lv` host lines, then re‑adds them as IPv4 only.
- Using only IPv4 prevents the browser from accidentally hitting an IPv6 vhost that serves a different certificate.

---

## 1) Create your local **root CA** (run once)

We’ll create a long‑lived root CA and store it under `/etc/local-ca`. This CA will sign per‑site certificates for your local domains.

```bash
sudo mkdir -p /etc/local-ca /etc/nginx/certs
cd /etc/local-ca
sudo openssl genrsa -out local-rootCA.key 4096
sudo openssl req -x509 -new -nodes -key local-rootCA.key -sha256 -days 3650 \
  -out local-rootCA.pem -subj "/C=XX/O=Local Dev CA/CN=Local Dev Root"
sudo chmod 600 local-rootCA.key
sudo chmod 644 local-rootCA.pem
```

**Notes**
- `local-rootCA.key` is your **private** root key — keep it safe (`600`).
- `local-rootCA.pem` is the **public** root certificate you’ll import into browsers.

---

## 2) Import the root CA into your browsers (run once)

We add the root to the **NSS** trust store used by **Snap Chromium** and **Snap Firefox**. Close browsers before running this, then fully reopen them afterwards.

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

**Tips**
- If the command prompts for an NSS password, create an empty store with `--empty-password` as shown.
- After import, **restart** the browsers. If you previously visited these domains, clear HSTS for them (Chrome: `chrome://net-internals/#hsts` → Delete; Firefox: History → “Forget about this site”).

---

## 3) Issue per‑domain certificates (repeat per site)

We’ll create keys and CSRs, add SANs, sign them with the local root, and build `fullchain` files that Nginx will serve.

### 3.1 `sandbox.lv`

```bash
DIR=/etc/nginx/certs

# ключ + CSR
sudo openssl genrsa -out $DIR/sandbox.lv.key 2048
sudo openssl req -new -key $DIR/sandbox.lv.key -out $DIR/sandbox.lv.csr -subj "/CN=sandbox.lv"

# SAN-настройки
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

# подпись от нашего корня + fullchain
sudo openssl x509 -req -in $DIR/sandbox.lv.csr -CA /etc/local-ca/local-rootCA.pem -CAkey /etc/local-ca/local-rootCA.key -CAcreateserial -out $DIR/sandbox.lv.crt -days 825 -sha256 -extfile $DIR/sandbox.lv.ext
sudo bash -c 'cat /etc/nginx/certs/sandbox.lv.crt /etc/local-ca/local-rootCA.pem > /etc/nginx/certs/sandbox.lv-fullchain.crt'
sudo chmod 600 $DIR/sandbox.lv.key
sudo chmod 644 $DIR/sandbox.lv.crt $DIR/sandbox.lv-fullchain.crt
```

### 3.2 `adminer.lv`

```bash
# ключ + CSR
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

**Why `fullchain`?**  
Nginx serves the leaf cert plus the root in one file so clients can build the trust path without extra configuration.

---

## 4) Enable HTTPS in Nginx

We’ll add a redirect from HTTP to HTTPS and a proper TLS server for each domain, pointing at the per‑site `fullchain`/`key` you just created.

### `sandbox.lv`

```bash
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
```

### `adminer.lv`

```bash
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
```

Apply the config:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

**Notes**
- Make sure PHP‑FPM is running and the socket path matches (`/run/php/php8.4-fpm.sock`).
- If your Laravel app shows 500, it’s an app issue (APP_KEY, permissions, caches) — not Nginx/TLS.

---

## 5) Verify

Use `openssl s_client` to confirm the served certificate contains the correct SANs. You should see your domain names listed under `subjectAltName`.

```bash
# должен показывать SAN с нужными доменами
openssl s_client -connect 127.0.0.1:443 -servername sandbox.lv  </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
openssl s_client -connect 127.0.0.1:443 -servername adminer.lv </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
```

If browsers still show trust warnings:
- Re‑check Step 2 (root CA import into NSS). Close all browser windows and reopen.
- Clear HSTS for these domains if you previously visited them with different settings.

---

## Adding more sites later

For any new domain (e.g., `blog.lv`), repeat **Step 3** (issue cert with SANs), add a new Nginx server block like in **Step 4** (pointing to `/etc/nginx/certs/blog.lv-fullchain.crt` and `blog.lv.key`), then reload Nginx and verify as in **Step 5**.

Happy hacking! 🚀
