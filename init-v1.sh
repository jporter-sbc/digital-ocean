#!/bin/bash
# init-v1.sh - Reliable base init for DigitalOcean droplets (v1.2)
# Goals:
# - Bring up Apache with a real :80 vhost
# - Deploy a test page
# - Get Let's Encrypt working automatically when DNS is ready (with retry timer)
# - Create a non-root sudo user with SSH key from DO metadata

set -euo pipefail

LOG="/var/log/do-init.log"
echo "[$(date)] Real init v1.2 started (from GitHub)" > "$LOG"

log() { echo "[$(date)] $*" | tee -a "$LOG" >/dev/null; }

# -------------------------
# Variables (override via env if desired)
# -------------------------
DOMAIN="${DOMAIN:-pjcard.com}"
WWW_DOMAIN="${WWW_DOMAIN:-www.${DOMAIN}}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"
USER="${APP_USER:-appuser}"

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

# Remove default pages (ignore if absent)
rm -f /var/www/html/index.nginx-debian.html /var/www/html/index.html || true

cat > /var/www/html/index.html << 'EOF'
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
  <p>This is the new DigitalOcean server for pjcard.com</p>
  <p><small>Test page - safe to remove later</small></p>
</body>
</html>
EOF

chown www-data:www-data /var/www/html/index.html || true
chmod 644 /var/www/html/index.html || true

# -------------------------
# Ensure a real :80 vhost exists for Certbot (CRITICAL)
# -------------------------
log "Configuring Apache vhost on :80 for ${DOMAIN} (+ ${WWW_DOMAIN})"
a2enmod rewrite || true

cat > /etc/apache2/sites-available/${DOMAIN}.http.conf <<EOF
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

a2ensite "${DOMAIN}.http.conf" || true
a2ensite 000-default.conf || true   # keep enabled so something always listens on :80
systemctl enable apache2 || true
systemctl restart apache2 || true

# Quick local test
if curl -s http://localhost | grep -q "You have reached your Droplet"; then
  log "Test page is live (local check OK)"
else
  log "WARNING: Test page not detected locally"
fi

# -------------------------
# Certbot via snap (Ubuntu 24.04+)
# -------------------------
log "Installing/refreshing snapd + certbot"
apt-get install -y snapd || true

# Make sure snapd is actually running before snap install (important in cloud-init)
systemctl enable --now snapd.socket || true
systemctl start snapd || true

snap install core || true
snap refresh core || true
snap install --classic certbot || true
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
    log "DNS: ${WWW_DOMAIN} resolves correctly; including in cert"
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
# Automatic HTTPS bootstrap with retry timer
# -------------------------
log "Setting up Certbot bootstrap (automatic retry until DNS ready)"

cat > /usr/local/sbin/certbot-bootstrap.sh <<EOS
#!/bin/bash
set -euo pipefail

LOG="/var/log/do-init.log"
log() { echo "[\$(date)] \$*" | tee -a "\$LOG" >/dev/null; }

DOMAIN="${DOMAIN}"
WWW_DOMAIN="${WWW_DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL}"

PUBLIC_IP="\$(curl -s https://api.ipify.org || true)"

dns_ok() {
  local name="\$1"
  local got
  got="\$(dig +short A "\$name" | tail -n 1 || true)"
  [[ -n "\$got" && -n "\$PUBLIC_IP" && "\$got" == "\$PUBLIC_IP" ]]
}

if ! dns_ok "\$DOMAIN"; then
  log "Certbot bootstrap: DNS not ready for \$DOMAIN (want \$PUBLIC_IP). Will retry."
  exit 1
fi

domains=(-d "\$DOMAIN")
if dns_ok "\$WWW_DOMAIN"; then
  domains+=(-d "\$WWW_DOMAIN")
fi

log "Certbot bootstrap: attempting issuance for: \${domains[*]}"
/usr/bin/certbot --apache -n --agree-tos -m "\$ADMIN_EMAIL" "\${domains[@]}" --redirect --no-eff-email

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

# Attempt once now (won't fail the whole init if DNS isn't ready)
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
adduser --gecos "" --disabled-password "$USER" || true
usermod -aG sudo "$USER" || true
echo "$USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USER" || true
chmod 0440 "/etc/sudoers.d/$USER" || true

# SSH key from DO metadata (if present)
log "Installing SSH keys for ${USER} from DO metadata (if available)"
mkdir -p "/home/$USER/.ssh" || true
curl -fsS http://169.254.169.254/metadata/v1/public-keys > "/home/$USER/.ssh/authorized_keys" 2>/dev/null || true
chown -R "$USER:$USER" "/home/$USER/.ssh" || true
chmod 700 "/home/$USER/.ssh" || true
chmod 600 "/home/$USER/.ssh/authorized_keys" || true

log "Init v1.2 completed successfully"
date > /var/log/init-complete.txt
