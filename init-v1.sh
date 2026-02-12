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

# Add your custom stack here later, e.g.:
# apt-get install -y nginx docker-ce docker-ce-cli containerd.io
# usermod -aG docker $USER  # or create non-root user

echo "[$(date)] Init v1 completed successfully" >> "$LOG"
date > /var/log/init-complete.txt
