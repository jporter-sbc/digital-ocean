#!/bin/bash
# init-v1.sh - Reliable base init for DigitalOcean droplets (v1.3)
# - Apache + test page
# - Always creates/enables a real :80 vhost (needed for Certbot Apache plugin)
# - Certbot auto-issues when DNS points at this droplet (via retry timer)
# - Reads config from env or /etc/default/do-init (written by user-data)
# - Creates a non-root sudo user + installs DO metadata SSH keys

set -euo pipefail

LOG="/var/log/do-init.log"
echo "[$(date)] Real init v1.3 started (from GitHub)" > "$LOG"
log() { echo "[$(date)] $*" | tee -a "$LOG" >/dev/null; }

# -------------------------
# Load config from /etc/default/do-init if present
# -------------------------
if [[ -f /etc/default/do-init ]]; then
  # shellcheck disable=SC1091
  source /etc/default/do-init
  log "Loaded config from /etc/default/do-init"
fi

# -------------------------
# Variables (override via env or /etc/default/do-init)
# -------------------------
DOMAIN="${DOMAIN:-}"
WWW_DOMAIN="${WWW_DOMAIN:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
USER="${APP_USER:-appuser}"

# Hard requirement: DOMAIN and ADMIN_EMAIL
if [[ -z "${DOMAIN}" ]]; then
  log "ERROR: DOMAIN is not set. Provide via env or /etc/default/do-init"
  exit 1
fi
if [[ -z "${WWW_DOMAIN}" ]]; then
  WWW_DOMAIN="www.${DOMAIN}"
fi
if [[ -z "${ADMIN_EMAIL}" ]]; then
  log "ERROR: ADMIN_EMAIL is not set. Provide via env or /etc/default/do-init"
  exit 1
fi
# -------------------------
# Floating IP assignment (must happen before certbot)
# -------------------------
apt-get update -qq || true
apt-get install -y --no-install-recommends curl ca-certificates || true

if [[ -n "${DO_API_TOKEN:-}" && -n "${FLOATING_IP:-}" ]]; then
  DROPLET_ID="$(curl -fsS http://169.254.169.254/metadata/v1/id || true)"
  log "Assigning Floating IP ${FLOATING_IP} to droplet ${DROPLET_ID}"

  curl -fsS -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${DO_API_TOKEN}" \
    "https://api.digitalocean.com/v2/floating_ips/${FLOATING_IP}/actions" \
    -d "{\"type\":\"assign\",\"droplet_id\":${DROPLET_ID}}" \
    >> "$LOG" 2>&1 || log "WARNING: Floating IP assignment API call failed"

  # Wait up to ~2 minutes for attachment (prevents certbot/dns race)
  for _ in {1..24}; do
    CUR="$(curl -s https://api.ipify.org || true)"
    [[ "$CUR" == "$FLOATING_IP" ]] && break
    sleep 5
  done

  log "Public IP after assignment: $(curl -s https://api.ipify.org || true)"
else
  log "Floating IP assignment skipped (missing DO_API_TOKEN or FLOATING_IP)"
fi

# -------------------------
# Firewall early
# -------------------------
log "Firewall: allow SSH/HTTP/HTTPS"
apt-get update -qq || true
apt-get install -y ufw || true
ufw allow OpenSSH comment 'SSH - keep access' || true
ufw allow 80/tcp comment 'HTTP' || true
ufw allow 443/tcp comment 'HTTPS' || true
ufw --force enable || true

# -------------------------
# Minimal prep + common tools
# -------------------------
log "Security upgrade + basics"
apt-get upgrade --security -y -qq || true
apt-get install -y --no-install-recommends \
  curl wget ca-certificates git unzip jq htop dnsutils || true

# -------------------------
# Install Apache + deploy test page
# -------------------------
log "Installing Apache + deploying index.html"
apt-get install -y --no-install-recommends apache2 || { log "Apache install failed"; exit 1; }

rm -f /var/www/html/index.nginx-debian.html /var/www/html/index.html || true

cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Droplet Test Page</title>
  <style>
    body { font-family: Arial, sans-serif; text-align: center; padding: 100px; background: #f0f8ff; }
    h1 { color: #0066cc; }
    p { font-size: 1.3em; }
  </style>
</head>
<body>
  <h1>You have reached your Droplet</h1>
  <p>This is the DigitalOcean server for ${DOMAIN}</p>
  <p><small>Test page - safe to remove later</small></p>
</body>
</html>
EOF

chown www-data:www-data /var/www/html/index.html || true
chmod 644 /var/www/html/index.html || true

# -------------------------
# Ensure a real :80 vhost exists (CRITICAL for Certbot)
# -------------------------
log "Configuring Apache :80 vhost for ${DOMAIN} (+ ${WWW_DOMAIN})"
a2enmod rewrite >/dev/null 2>&1 || true

cat > "/etc/apache2/sites-available/${DOMAIN}.http.conf" <<EOF
<VirtualHost *:80>
  ServerName ${DOMAIN}
  ServerAlias ${WWW_DOMAIN}
  DocumentRoot /var/www/html

  <Directory /var/www/html>
    AllowOverride All
    Require all granted
  </Directory>

  ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-error.log
  CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined
</VirtualHost>
EOF

a2ensite "${DOMAIN}.http.conf" >/dev/null 2>&1 || true
a2ensite 000-default.conf >/dev/null 2>&1 || true  # keep something always listening on :80

systemctl enable apache2 >/dev/null 2>&1 || true
systemctl restart apache2 || true

log "Apache vhosts:"
apache2ctl -S 2>&1 | tee -a "$LOG" >/dev/null || true

# Local test
if curl -s http://localhost | grep -q "You have reached your Droplet"; then
  log "HTTP test page OK (local)"
else
  log "WARNING: HTTP test page not detected locally"
fi

# -------------------------
# Certbot via snap (Ubuntu 24.04+)
# -------------------------
log "Installing/refreshing snapd + certbot"
apt-get install -y snapd || true
systemctl enable --now snapd.socket >/dev/null 2>&1 || true
systemctl start snapd >/dev/null 2>&1 || true

snap install core >/dev/null 2>&1 || true
snap refresh core >/dev/null 2>&1 || true
snap install --classic certbot >/dev/null 2>&1 || true
ln -sf /snap/bin/certbot /usr/bin/certbot || true

# -------------------------
# DNS readiness helpers
# -------------------------
PUBLIC_IP="$(curl -s https://api.ipify.org || true)"

dns_ok() {
  local name="$1"
  local got
  got="$(dig +short A "$name" | tail -n 1 || true)"
  [[ -n "$got" && -n "$PUBLIC_IP" && "$got" == "$PUBLIC_IP" ]]
}

issue_cert() {
  local domains=(-d "$DOMAIN")
  if dns_ok "$WWW_DOMAIN"; then
    domains+=(-d "$WWW_DOMAIN")
    log "DNS: ${WWW_DOMAIN} resolves to droplet; including in cert"
  else
    log "DNS: ${WWW_DOMAIN} not ready; issuing cert for apex only"
  fi

  certbot --apache \
    --non-interactive \
    --agree-tos \
    --email "$ADMIN_EMAIL" \
    "${domains[@]}" \
    --redirect \
    --no-eff-email
}

# -------------------------
# Certbot bootstrap retry timer (automates “DNS later”)
# -------------------------
log "Setting up Certbot bootstrap retry timer"

cat > /usr/local/sbin/certbot-bootstrap.sh <<EOS
#!/bin/bash
set -euo pipefail

LOG="/var/log/do-init.log"
log() { echo "[\$(date)] \$*" | tee -a "\$LOG" >/dev/null; }

DOMAIN="${DOMAIN}"
WWW_DOMAIN="${WWW_DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL}"

# Ensure deps exist (timer can fire later, but keep it self-healing)
command -v dig >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y dnsutils) || true
command -v certbot >/dev/null 2>&1 || exit 1

PUBLIC_IP="\$(curl -s https://api.ipify.org || true)"

dns_ok() {
  local name="\$1"
  local got
  got="\$(dig +short A "\$name" | tail -n 1 || true)"
  [[ -n "\$got" && -n "\$PUBLIC_IP" && "\$got" == "\$PUBLIC_IP" ]]
}

# Must have apex pointing here first
if ! dns_ok "\$DOMAIN"; then
  log "Certbot bootstrap: DNS not ready for \$DOMAIN (want \$PUBLIC_IP). Will retry."
  exit 1
fi

# Apache must be listening on :80
if ! ss -lnt | grep -q ':80'; then
  log "Certbot bootstrap: Apache not listening on :80 yet. Will retry."
  exit 1
fi

domains=(-d "\$DOMAIN")
if dns_ok "\$WWW_DOMAIN"; then
  domains+=(-d "\$WWW_DOMAIN")
fi

log "Certbot bootstrap: attempting issuance for: \${domains[*]}"
certbot --apache -n --agree-tos -m "\$ADMIN_EMAIL" "\${domains[@]}" --redirect --no-eff-email

log "Certbot bootstrap: success. Disabling retry timer."
systemctl disable --now certbot-bootstrap.timer || true
exit 0
EOS

chmod +x /usr/local/sbin/certbot-bootstrap.sh

cat > /etc/systemd/system/certbot-bootstrap.service <<'EOF'
[Unit]
Description=Bootstrap Let's Encrypt cert once DNS is ready
After=network-online.target apache2.service snapd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/certbot-bootstrap.sh
EOF

cat > /etc/systemd/system/certbot-bootstrap.timer <<'EOF'
[Unit]
Description=Retry Let's Encrypt bootstrap until success

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now certbot-bootstrap.timer

# Try once now (won't fail init if DNS isn't ready)
if dns_ok "$DOMAIN"; then
  log "DNS ready now; attempting Certbot immediately"
  if issue_cert; then
    log "Certbot immediate issuance succeeded; disabling retry timer"
    systemctl disable --now certbot-bootstrap.timer || true
  else
    log "Certbot immediate attempt failed; timer will retry"
  fi
else
  log "DNS not ready now for ${DOMAIN}; timer will retry"
fi

# -------------------------
# Non-root user
# -------------------------
log "Creating non-root user: ${USER}"
adduser --gecos "" --disabled-password "$USER" >/dev/null 2>&1 || true
usermod -aG sudo "$USER" >/dev/null 2>&1 || true
echo "$USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USER" || true
chmod 0440 "/etc/sudoers.d/$USER" || true

log "Installing SSH keys for ${USER} from DO metadata (if available)"
mkdir -p "/home/$USER/.ssh" || true
curl -fsS http://169.254.169.254/metadata/v1/public-keys > "/home/$USER/.ssh/authorized_keys" 2>/dev/null || true
chown -R "$USER:$USER" "/home/$USER/.ssh" || true
chmod 700 "/home/$USER/.ssh" || true
chmod 600 "/home/$USER/.ssh/authorized_keys" || true

log "Init v1.3 completed successfully"
date > /var/log/init-complete.txt
