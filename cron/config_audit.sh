#!/bin/bash
# Configuration Audit Script
# Checks OpenClaw config integrity

LOG_DIR="/home/pi/.openclaw/workspace/logs"
LOG_FILE="$LOG_DIR/config_audit.log"
CONFIG_FILE="/home/pi/.openclaw/openclaw.json"
SNAPSHOT_DIR="$LOG_DIR/config_snapshots"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

mkdir -p "$SNAPSHOT_DIR"

# Create baseline snapshot if it doesn't exist
SNAPSHOT_FILE="$SNAPSHOT_DIR/openclaw_baseline.json"
if [[ ! -f "$SNAPSHOT_FILE" ]]; then
    echo "Creating baseline config snapshot..." >> "$LOG_FILE"
    cp "$CONFIG_FILE" "$SNAPSHOT_FILE"
fi

# Compare current config with baseline
echo "=== Configuration Audit - $TIMESTAMP ===" >> "$LOG_FILE"

if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    echo "⚠️ INVALID JSON in config!" >> "$LOG_FILE"
    exit 1
fi

DIFF_OUTPUT=$(diff <(jq -S . "$SNAPSHOT_FILE") <(jq -S . "$CONFIG_FILE"))

if [[ -n "$DIFF_OUTPUT" ]]; then
    echo "⚠️ CONFIGURATION CHANGES DETECTED!" >> "$LOG_FILE"
    echo "$DIFF_OUTPUT" >> "$LOG_FILE"
    
    # Send Telegram alert
    curl -s -X POST "https://api.telegram.org/bot8282800471:AAF-TZrTxX7M51lETMyIzDQN43ixkp2UTwE/sendMessage" \
        -d "chat_id=720036884" \
        -d "text=⚠️ OpenClaw config change detected!" >> "$LOG_FILE" 2>&1
    
    # Update baseline
    cp "$CONFIG_FILE" "$SNAPSHOT_FILE"
else
    echo "✅ No configuration changes detected" >> "$LOG_FILE"
fi

echo "=== Audit completed at $(date) ===" >> "$LOG_FILE"
exit 0
