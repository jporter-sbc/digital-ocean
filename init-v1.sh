#!/bin/bash
# init-v1.sh - Reliable base init for DigitalOcean droplets
# Plain text - edit in GitHub and commit

set -euo pipefail

LOG="/var/log/do-init.log"
echo "[$(date)] Real init v1 started (from GitHub)" > "$LOG"

# Protect SSH early
echo "[$(date)] Firewall: allow SSH" >> "$LOG"
apt-get update -qq || true
apt-get install -y ufw || true
ufw allow OpenSSH comment 'SSH - keep access' || true
ufw allow 80/tcp comment 'HTTP' || true
ufw allow 443/tcp comment 'HTTPS' || true
ufw --force enable || true

# Minimal prep + common tools
echo "[$(date)] Security upgrade + basics" >> "$LOG"
apt-get upgrade --security -y -qq || true
apt-get install -y --no-install-recommends \
    curl wget ca-certificates git unzip jq htop || true


# ────────────────────────────────────────────────
# Install Apache + deploy test page
# ────────────────────────────────────────────────
echo "[$(date)] Installing Apache + deploying index.html" >> "$LOG"

apt-get install -y --no-install-recommends \
    apache2 \
    || { echo "Apache install failed" >> "$LOG"; exit 1; }

# Remove default Ubuntu page
rm -f /var/www/html/index.nginx-debian.html /var/www/html/index.html || true

# Write your custom index.html
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

# Disable default site (prevents "It works!" or 404 confusion)
a2dissite 000-default.conf || true

# Make sure Apache is running
systemctl enable apache2 || true
systemctl restart apache2 || true

# Quick local test
if curl -s http://localhost | grep -q "You have reached your Droplet"; then
    echo "[$(date)] Test page is live (local check OK)" >> "$LOG"
else
    echo "[$(date)] WARNING: Test page not detected locally" >> "$LOG"
fi

# ────────────────────────────────────────────────
# Install Certbot & attempt automatic HTTPS (Let's Encrypt)
# ────────────────────────────────────────────────
echo "[$(date)] Setting up Certbot & HTTPS" >> "$LOG"

# Install snapd if missing (usually present, but safe)
apt-get install -y snapd || true

# Classic snap install for Certbot (recommended on Ubuntu 24.04+)
snap install core || true
snap refresh core || true
snap install --classic certbot || true

# Create symlink if needed
ln -sf /snap/bin/certbot /usr/bin/certbot || true

# Define domain(s) - make dynamic later via tags/metadata
DOMAIN="pjcard.com"                  # ← CHANGE THIS or make dynamic
WWW_DOMAIN="www.${DOMAIN}"           # optional
ADMIN_EMAIL="john.porter@securitybuildingcontrols.com"        # ← CHANGE THIS (used for renewal notices)

# Attempt non-interactive cert issuance + Apache config + redirect
# --non-interactive       : no prompts
# --agree-tos             : accept terms
# --email                 : for expiry/renewal emails
# --domains               : the domains to cover
# --apache                : auto-configures Apache vhost + redirect
# --redirect              : force HTTP → HTTPS (default behavior)
# --no-eff-email          : skip EFF newsletter (optional)

certbot --apache \
    --non-interactive \
    --agree-tos \
    --email "${ADMIN_EMAIL}" \
    --domains "${DOMAIN}" \
    --domains "${WWW_DOMAIN}" \
    --redirect \
    --no-eff-email \
    || {
        echo "[$(date)] Certbot failed (DNS not ready yet? Run manually later: sudo certbot --apache)" >> "$LOG"
        # No exit here - we don't want to fail the whole script if certbot can't run yet
    }

# Verify HTTPS locally (optional diagnostic)
if curl -s -k https://localhost | grep -q "You have reached your Droplet"; then
    echo "[$(date)] HTTPS test OK (local)" >> "$LOG"
else
    echo "[$(date)] HTTPS not active yet (expected if DNS not propagated)" >> "$LOG"
fi

# Certbot auto-renewal timer is created automatically - verify:
systemctl list-timers | grep certbot || echo "Certbot timer not found - check snap services" >> "$LOG"



# Non-root user (run after basics)
echo "[$(date)] Creating non-root user" >> "$LOG"
USER="appuser"
adduser --gecos "" --disabled-password "$USER" || true
usermod -aG sudo "$USER" || true
echo "$USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USER" || true
chmod 0440 "/etc/sudoers.d/$USER" || true

# Copy your SSH public key to the new user (fetch from metadata or hard-code for now)
mkdir -p /home/$USER/.ssh || true
curl -s http://169.254.169.254/metadata/v1/public-keys > /home/$USER/.ssh/authorized_keys || true
chown -R $USER:$USER /home/$USER/.ssh || true
chmod 700 /home/$USER/.ssh || true
chmod 600 /home/$USER/.ssh/authorized_keys || true


echo "[$(date)] Init v1 completed successfully" >> "$LOG"
date > /var/log/init-complete.txt
