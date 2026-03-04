#!/bin/bash
# Portfolio Value Calculator
# Reads current prices from prices.txt and sends to Telegram
# Fixed: DoD timing bug, loss sign display, bc validation

set -euo pipefail

PRICES_FILE="/home/pi/.openclaw/workspace/skills/portfolio/prices.txt"
LOG_FILE="/home/pi/.openclaw/workspace/logs/portfolio_value.log"
TOKEN_FILE="/home/pi/.openclaw/workspace/memory/telegram_bot_token.txt"
CHAT_ID="720036884"
HISTORY_FILE="/home/pi/.openclaw/workspace/skills/portfolio/portfolio_history.json"

# === Logging ===
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] ERROR: $*" >> "$LOG_FILE" >&2; }
log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" >> "$LOG_FILE"; }

# === Dependency Check ===
check_deps() {
    local missing=()
    for cmd in curl jq bc; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "❌ Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

# === Validate Numeric Value ===
validate_numeric() {
    local value="$1"
    if ! [[ "$value" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        log_error "Invalid numeric value: $value"
        return 1
    fi
    return 0
}

# === Get Sign Info for Display ===
get_sign_info() {
    local value="$1"
    local is_positive
    is_positive=$(echo "$value >= 0" | bc -l 2>/dev/null || echo "0")
    
    if [[ "$is_positive" == "1" ]]; then
        echo "positive:+:🟢"
    else
        echo "negative:-:🔴"
    fi
}

# === Portfolio: Symbol, Shares, Basis Price ===
declare -A portfolio
portfolio[PM]="19,114.80"
portfolio[INTC]="62,39.64"
portfolio[EPOL]="58,33.19"
portfolio[XLE]="20,28.32"
portfolio[AMZN]="8,96.75"
portfolio[VALE]="101,13.83"
portfolio[RTX]="7,85.33"
portfolio[OSBC]="121,19.95"

# === Validate Prices File ===
if [[ ! -f "$PRICES_FILE" ]]; then
    log_error "❌ Prices file not found: $PRICES_FILE"
    echo "ERROR: Prices file not found. Please update prices.txt first."
    exit 1
fi

if [[ ! -r "$PRICES_FILE" ]]; then
    log_error "❌ Prices file not readable: $PRICES_FILE"
    echo "ERROR: Cannot read prices file."
    exit 1
fi

if [[ ! -s "$PRICES_FILE" ]]; then
    log_error "❌ Prices file is empty: $PRICES_FILE"
    echo "ERROR: Prices file is empty."
    exit 1
fi

# === Read Current Prices ===
declare -A prices
while IFS=',' read -r symbol price; do
    [[ -z "$symbol" || "$symbol" =~ ^# ]] && continue
    [[ -z "$price" ]] && continue
    if ! validate_numeric "$price"; then
        log_error "⚠️ Invalid price for $symbol: $price (skipping)"
        continue
    fi
    prices[$symbol]=$price
done < "$PRICES_FILE"

if [[ ${#prices[@]} -eq 0 ]]; then
    log_error "❌ No valid prices loaded from $PRICES_FILE"
    echo "ERROR: No valid prices found in prices.txt"
    exit 1
fi

# === Run Dependency Check ===
check_deps

log_info "========================================="
log_info "Portfolio Value - $(date '+%Y-%m-%d')"
log_info "========================================="

TOTAL_COST=0
TOTAL_VALUE=0

# === Calculate Portfolio Values ===
for symbol in "${!portfolio[@]}"; do
    IFS=',' read -r shares basis <<< "${portfolio[$symbol]}"
    current="${prices[$symbol]:-0}"
    
    # Validate inputs before calculation
    if ! validate_numeric "$shares" || ! validate_numeric "$basis" || ! validate_numeric "$current"; then
        log_error "Skipping $symbol due to invalid values"
        continue
    fi
    
    # Calculate with proper error handling
    if ! cost=$(echo "$shares * $basis" | bc 2>/dev/null); then
        log_error "BC calculation failed for $symbol cost"
        cost=0
    fi
    
    if ! value=$(echo "$shares * $current" | bc 2>/dev/null); then
        log_error "BC calculation failed for $symbol value"
        value=0
    fi
    
    if ! gain=$(echo "$value - $cost" | bc 2>/dev/null); then
        log_error "BC calculation failed for $symbol gain"
        gain=0
    fi
    
    if [[ "$cost" != "0" ]] && [[ "$cost" != "0.00" ]]; then
        gain_pct=$(echo "scale=1; ($gain / $cost) * 100" | bc 2>/dev/null || echo "0")
    else
        gain_pct="0"
    fi
    
    TOTAL_COST=$(echo "$TOTAL_COST + $cost" | bc)
    TOTAL_VALUE=$(echo "$TOTAL_VALUE + $value" | bc)
    
    # Format display with proper sign
    sign_info=$(get_sign_info "$gain")
    status=$(echo "$sign_info" | cut -d':' -f1)
    sign_prefix=$(echo "$sign_info" | cut -d':' -f2)
    emoji=$(echo "$sign_info" | cut -d':' -f3)
    
    if [[ "$status" == "positive" ]]; then
        log_info "$symbol | $shares @ \$$current | Gain: +\$$gain (+${gain_pct}%) $emoji"
    else
        log_info "$symbol | $shares @ \$$current | Loss: \$$gain (${gain_pct}%) $emoji"
    fi
done

# === Calculate Total Gain/Loss ===
if ! TOTAL_GAIN=$(echo "$TOTAL_VALUE - $TOTAL_COST" | bc 2>/dev/null); then
    log_error "BC calculation failed for total gain"
    TOTAL_GAIN=0
fi

if [[ "$TOTAL_COST" != "0" ]] && [[ "$TOTAL_COST" != "0.00" ]]; then
    GAIN_PCT=$(echo "scale=1; ($TOTAL_GAIN / $TOTAL_COST) * 100" | bc 2>/dev/null || echo "0")
else
    GAIN_PCT="0"
fi

log_info ""
log_info "========================================="
log_info "Total Cost: \$$TOTAL_COST"
log_info "Total Value: \$$TOTAL_VALUE"

# Format total gain/loss display
sign_info=$(get_sign_info "$TOTAL_GAIN")
status=$(echo "$sign_info" | cut -d':' -f1)
if [[ "$status" == "positive" ]]; then
    log_info "Total Gain: +\$$TOTAL_GAIN (+${GAIN_PCT}%) [All-Time] 🟢"
else
    log_info "Total Loss: \$$TOTAL_GAIN (${GAIN_PCT}%) [All-Time] 🔴"
fi

# === Day-over-Day Calculation (AFTER TOTAL_VALUE is calculated) ===
DOD_CHANGE=0
DOD_CHANGE_PCT=0
DOD_ARROW=""
DOD_SIGN=""

today_date=$(date '+%Y-%m-%d')
yesterday_date=$(date -d "yesterday" '+%Y-%m-%d')

# Load yesterday's value if history exists
if [[ -f "$HISTORY_FILE" ]]; then
    # Validate JSON structure first
    if ! jq empty "$HISTORY_FILE" 2>/dev/null; then
        log_error "History file contains invalid JSON, resetting..."
        echo '{"history":{}}' > "$HISTORY_FILE"
    fi
    
    DOD_YESTERDAY=$(jq -r --arg date "$yesterday_date" '.history[$date] // empty' "$HISTORY_FILE" 2>/dev/null || echo "")
    
    # Validate retrieved value is numeric and non-zero
    if [[ -n "$DOD_YESTERDAY" ]] && [[ "$DOD_YESTERDAY" != "null" ]] && [[ "$DOD_YESTERDAY" != "0" ]] && validate_numeric "$DOD_YESTERDAY"; then
        # Calculate DoD change with proper error handling
        if ! DOD_CHANGE=$(echo "scale=2; $TOTAL_VALUE - $DOD_YESTERDAY" | bc 2>/dev/null); then
            log_error "BC calculation failed for DoD change"
            DOD_CHANGE=0
        fi
        
        # Calculate percentage with division by zero protection
        if [[ "$DOD_YESTERDAY" != "0" ]]; then
            if ! DOD_CHANGE_PCT=$(echo "scale=2; ($DOD_CHANGE / $DOD_YESTERDAY) * 100" | bc 2>/dev/null); then
                log_error "BC calculation failed for DoD percentage"
                DOD_CHANGE_PCT=0
            fi
        fi
        
        # Get proper sign info for DoD (with explicit minus for losses)
        dod_sign_info=$(get_sign_info "$DOD_CHANGE")
        dod_status=$(echo "$dod_sign_info" | cut -d':' -f1)
        DOD_SIGN=$(echo "$dod_sign_info" | cut -d':' -f2)
        DOD_ARROW=$(echo "$dod_sign_info" | cut -d':' -f3)
        
        log_info "Day Change: ${DOD_SIGN}\$$DOD_CHANGE (${DOD_CHANGE_PCT}%) $DOD_ARROW"
    else
        log_info "Day Change: N/A (first run or no prior data)"
        DOD_SIGN=""
        DOD_ARROW=""
    fi
else
    log_info "Day Change: N/A (first run or no prior data)"
fi

log_info "========================================="

# === Save Today's Value to History (AFTER all calculations) ===
mkdir -p "$(dirname "$HISTORY_FILE")"
if [[ -f "$HISTORY_FILE" ]]; then
    # Validate JSON before modifying
    if jq empty "$HISTORY_FILE" 2>/dev/null; then
        if ! jq --arg date "$today_date" --argjson value "$TOTAL_VALUE" \
           '.history[$date] = $value' "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" 2>/dev/null; then
            log_error "Failed to update history file"
        else
            mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
            log_info "History file updated: $today_date = \$$TOTAL_VALUE"
        fi
    else
        log_error "History file corrupted, creating fresh"
        echo "{\"history\":{\"$today_date\":$TOTAL_VALUE}}" > "$HISTORY_FILE"
    fi
else
    echo "{\"history\":{\"$today_date\":$TOTAL_VALUE}}" > "$HISTORY_FILE"
    log_info "History file created: $today_date = \$$TOTAL_VALUE"
fi

# === Format DoD for Telegram ===
# Escape dollar sign for Telegram Markdown v2
if [[ -n "$DOD_SIGN" ]] && [[ "$DOD_SIGN" != "" ]]; then
    DOD_TELEGRAM="${DOD_SIGN}$${DOD_CHANGE} (${DOD_SIGN}${DOD_CHANGE_PCT}%) $DOD_ARROW"
else
    DOD_TELEGRAM="N/A (first run)"
fi

# === Format All-Time for Telegram ===
# Escape dollar sign for Telegram Markdown v2
if [[ "$status" == "positive" ]]; then
    ALL_TIME_TELEGRAM="+$${TOTAL_GAIN} (+${GAIN_PCT}%)"
else
    ALL_TIME_TELEGRAM="$${TOTAL_GAIN} (${GAIN_PCT}%)"
fi

# === Send to Telegram ===
if [[ -f "$TOKEN_FILE" ]]; then
    TG_TOKEN=$(cat "$TOKEN_FILE")
    
    MESSAGE="📊 *Portfolio Update - $(date '+%m/%d')*%0A%0A"
    MESSAGE+="PM | INTC | EPOL | XLE%0A"
    MESSAGE+="AMZN | VALE | RTX | OSBC%0A%0A"
    MESSAGE+="*Total: $${TOTAL_VALUE}* ($${TOTAL_COST} basis)%0A%0A"
    MESSAGE+="*All-Time P&L:* ${ALL_TIME_TELEGRAM}%0A"
    MESSAGE+="*Day-over-Day:* ${DOD_TELEGRAM}"
    
    # Send to Telegram with retry and timeout
    MAX_RETRIES=3
    RETRY_DELAY=2
    
    for i in $(seq 1 $MAX_RETRIES); do
        RESPONSE=$(curl -s --max-time 30 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d "chat_id=$CHAT_ID" \
            -d "text=$MESSAGE" \
            -d "parse_mode=Markdown" 2>/dev/null)
        
        log_info "Attempt $i/$MAX_RETRIES - Response: $RESPONSE"
        
        if echo "$RESPONSE" | jq -r '.ok' 2>/dev/null | grep -q "true"; then
            log_info "✅ Telegram message sent successfully"
            break
        else
            log_info "⚠️ Telegram send failed (attempt $i/$MAX_RETRIES)"
            if [ $i -lt $MAX_RETRIES ]; then
                sleep $RETRY_DELAY
            else
                log_error "All $MAX_RETRIES Telegram send attempts failed"
            fi
        fi
    done
    
    unset TG_TOKEN
fi

log_info "Portfolio calculated: \$$TOTAL_VALUE vs \$$TOTAL_COST cost (DoD: ${DOD_SIGN}\$$DOD_CHANGE)"
