#!/bin/bash
# DO Fetcher v1 - pulls real init from GitHub raw

set -e

SCRIPT_URL="https://raw.githubusercontent.com/yourusername/do-droplet-init-scripts/main/init-v1.sh"
# ↑ Replace with your actual raw URL

LOG="/var/log/fetcher.log"
echo "[$(date)] Fetcher started - pulling $SCRIPT_URL" > "$LOG"

# Ensure curl is available
apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates

# Download
curl -fsSL -o /tmp/real-init.sh "$SCRIPT_URL" >> "$LOG" 2>&1 || {
  echo "[$(date)] Download failed - check URL/network" >> "$LOG"
  exit 1
}

chmod +x /tmp/real-init.sh
echo "[$(date)] Executing real script" >> "$LOG"

/tmp/real-init.sh >> "$LOG" 2>&1

echo "[$(date)] Fetcher done (real script exit: $?)" >> "$LOG"
rm -f /tmp/real-init.sh || true
