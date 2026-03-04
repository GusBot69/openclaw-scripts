#!/bin/bash
# SSH Login Failure Detection Script
# Monitors journalctl for failed SSH attempts and sends alerts

LOG_DIR="/home/pi/.openclaw/workspace/logs"
LOG_FILE="$LOG_DIR/ssh_security.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

# Telegram config
TG_BOT_TOKEN="8282800471:AAF-TZrTxX7M51lETMyIzDQN43ixkp2UTwE"
TG_CHAT_ID="720036884"

mkdir -p "$LOG_DIR"

echo "=== SSH Security Scan - $TIMESTAMP ===" >> "$LOG_FILE"

# Check for failed login attempts using journalctl (works in containers)
FAILED_LOGINS=$(journalctl -u ssh 2>/dev/null | grep 'Failed password' | tail -n 5)

# Also check for SSHd directly
if [[ -z "$FAILED_LOGINS" ]]; then
    FAILED_LOGINS=$(journalctl -u sshd 2>/dev/null | grep 'Failed password' | tail -n 5)
fi

if [[ -n "$FAILED_LOGINS" ]]; then
    echo "⚠️ FAILED SSH LOGIN DETECTED!" >> "$LOG_FILE"
    echo "Attempts:" >> "$LOG_FILE"
    echo "$FAILED_LOGINS" >> "$LOG_FILE"
    
    # Send Telegram alert
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TG_CHAT_ID" \
        -d "text=⚠️ SSH SECURITY ALERT: Failed login attempts detected!" >> "$LOG_FILE" 2>&1
else
    echo "✅ No failed SSH attempts detected" >> "$LOG_FILE"
fi

echo "=== Scan completed at $(date) ===" >> "$LOG_FILE"
