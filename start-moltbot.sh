#!/bin/bash
# OpenClaw Startup Script v45 - With Telegram via env var
# Cache bust: 2026-02-05-v45-telegram-env

echo "============================================"
echo "Starting OpenClaw v45"
echo "============================================"

CONFIG_DIR="/root/.openclaw"
mkdir -p "$CONFIG_DIR"

# Create minimal config - Telegram token is read from TELEGRAM_BOT_TOKEN env var
cat > "$CONFIG_DIR/openclaw.json" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG

echo "Config written:"
cat "$CONFIG_DIR/openclaw.json"

# Check if TELEGRAM_BOT_TOKEN is set
if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
  echo "TELEGRAM_BOT_TOKEN is set, Telegram should be auto-configured"
fi

# Run doctor to auto-configure channels from environment
echo "Running openclaw doctor --fix..."
openclaw doctor --fix || true

echo "Starting gateway..."
exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
