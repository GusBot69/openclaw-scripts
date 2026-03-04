#!/bin/bash
# Fetch Stock Prices from Alpha Vantage API
# Runs at 3:05 PM CT (5 minutes after market close)
# Updates prices.txt for portfolio_value.sh
# Alpha Vantage free tier: 25 calls/day, 5 calls/min

set -euo pipefail

PRICES_FILE="/home/pi/.openclaw/workspace/skills/portfolio/prices.txt"
LOG_FILE="/home/pi/.openclaw/workspace/logs/fetch_stock_prices.log"
STATE_FILE="/home/pi/.openclaw/workspace/memory/alpha_vantage_state.json"

# Constants
readonly MAX_API_CALLS_PER_DAY=25
readonly RATE_LIMIT_DELAY=12
readonly MIN_SUCCESS_THRESHOLD=6
readonly MAX_RETRIES=1

# Stock symbols to fetch
declare -a SYMBOLS=("PM" "INTC" "EPOL" "XLE" "AMZN" "VALE" "RTX" "OSBC")

# === Logging ===
log() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" >> "$LOG_FILE"
}

log_error() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] ERROR: $*" >> "$LOG_FILE" >&2
}

# === Dependency Check ===
check_deps() {
    local missing=()
    for cmd in curl jq date; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

# === Initialize State File ===
init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << 'EOF'
{
    "last_fetch": "",
    "calls_today": 0,
    "last_reset_date": ""
}
EOF
    fi
}

# === Check Rate Limit ===
check_rate_limit() {
    local today
    today=$(date '+%Y-%m-%d')
    local last_reset
    last_reset=$(jq -r '.last_reset_date // empty' "$STATE_FILE" 2>/dev/null)
    
    # Reset counter if new day
    if [[ "$last_reset" != "$today" ]]; then
        log "Resetting daily call counter (new day: $today)"
        local temp_file
        temp_file=$(mktemp)
        jq --arg date "$today" '.last_reset_date = $date | .calls_today = 0' "$STATE_FILE" > "$temp_file" && mv "$temp_file" "$STATE_FILE"
    fi
    
    local calls_today
    calls_today=$(jq -r '.calls_today // 0' "$STATE_FILE" 2>/dev/null)
    
    if [[ "$calls_today" -ge "$MAX_API_CALLS_PER_DAY" ]]; then
        log_error "Daily API limit reached ($calls_today/$MAX_API_CALLS_PER_DAY calls)"
        exit 1
    fi
    
    log "API calls today: $calls_today/$MAX_API_CALLS_PER_DAY"
}

# === Increment Call Counter ===
increment_calls() {
    local temp_file
    temp_file=$(mktemp)
    jq '.calls_today += 1' "$STATE_FILE" > "$temp_file" && mv "$temp_file" "$STATE_FILE"
}

# === Fetch Single Stock Price ===
fetch_stock_price() {
    local symbol="$1"
    local api_key="$2"
    local retry=0
    
    while [[ $retry -lt $MAX_RETRIES ]]; do
        # Alpha Vantage GLOBAL_QUOTE endpoint
        local response
        response=$(curl -s --max-time 10 \
            "https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=${symbol}&apikey=${api_key}" 2>/dev/null)
        
        # Check for API error messages
        if echo "$response" | jq -e '.["Error Message"]' >/dev/null 2>&1; then
            local error_msg
            error_msg=$(echo "$response" | jq -r '.["Error Message"]')
            log_error "API error for $symbol: $error_msg"
            return 1
        fi
        
        # Check for API note (rate limit)
        if echo "$response" | jq -e '.Note' >/dev/null 2>&1; then
            local note
            note=$(echo "$response" | jq -r '.Note')
            log_error "API note for $symbol: $note"
            return 1
        fi
        
        # Extract price from GLOBAL_QUOTE response
        local price
        price=$(echo "$response" | jq -r '.["Global Quote"]["05. price"] // empty' 2>/dev/null)
        
        # Validate price (not empty, not N/A, is numeric)
        if [[ -n "$price" ]] && [[ "$price" != "null" ]] && [[ "$price" != "N/A" ]]; then
            if [[ "$price" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                echo "$price"
                return 0
            fi
        fi
        
        log_error "Invalid or missing price for $symbol (attempt $((retry + 1)))"
        retry=$((retry + 1))
        sleep $((retry * 2))
    done
    
    log_error "All $MAX_RETRIES attempts failed for $symbol"
    return 1
}

# === Check if Market Day (skip weekends) ===
is_market_day() {
    local day_of_week
    day_of_week=$(date '+%u')
    
    # 6=Saturday, 7=Sunday
    if [[ "$day_of_week" -ge 6 ]]; then
        return 1
    fi
    return 0
}

# === Main Execution ===
main() {
    log "=== Starting stock price fetch ==="
    
    # Check if market day
    if ! is_market_day; then
        log "Skipping fetch - market closed (weekend)"
        exit 0
    fi
    
    # Initialize
    check_deps
    init_state
    check_rate_limit
    
    # Load API key from config
    local api_key
    if ! api_key=$(jq -r '.secrets.alpha_vantage_api_key // empty' "/home/pi/.openclaw/openclaw.json" 2>/dev/null); then
        log_error "Could not load Alpha Vantage API key from config"
        exit 1
    fi
    
    if [[ -z "$api_key" ]] || [[ "$api_key" == "null" ]]; then
        log_error "Alpha Vantage API key not configured"
        log_error "Get free API key at: https://www.alphavantage.co/support/#api-key"
        exit 1
    fi
    
    # Backup existing prices file
    if [[ -f "$PRICES_FILE" ]]; then
        cp "$PRICES_FILE" "${PRICES_FILE}.backup"
        log "Backed up existing prices file"
    fi
    
    # Create temporary prices file
    local temp_prices
    temp_prices=$(mktemp)
    
    # Write header
    echo "# Current prices (updated $(date '+%Y-%m-%d %H:%M:%S %Z'))" > "$temp_prices"
    echo "# Format: SYMBOL,PRICE" >> "$temp_prices"
    
    # Fetch each stock price
    local success_count=0
    local fail_count=0
    
    for symbol in "${SYMBOLS[@]}"; do
        log "Fetching $symbol..."
        
        local price
        if price=$(fetch_stock_price "$symbol" "$api_key"); then
            echo "${symbol},${price}" >> "$temp_prices"
            log "✅ $symbol: \$${price}"
            success_count=$((success_count + 1))
            increment_calls
        else
            log_error "❌ Failed to fetch $symbol"
            fail_count=$((fail_count + 1))
        fi
        
        # Rate limit: 5 calls per minute
        sleep $RATE_LIMIT_DELAY
    done
    
    # Check if we got enough prices
    if [[ $success_count -lt $MIN_SUCCESS_THRESHOLD ]]; then
        log_error "Only $success_count/${#SYMBOLS[@]} prices fetched successfully"
        rm -f "$temp_prices"
        exit 1
    fi
    
    # Move temp file to final location
    mv "$temp_prices" "$PRICES_FILE"
    
    # Update state
    local temp_state
    temp_state=$(mktemp)
    jq --arg fetch_time "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
       '.last_fetch = $fetch_time' "$STATE_FILE" > "$temp_state" && mv "$temp_state" "$STATE_FILE"
    
    log "=== Stock price fetch complete ==="
    log "✅ Successfully fetched $success_count/${#SYMBOLS[@]} prices"
    log "❌ Failed: $fail_count"
    log "Updated: $PRICES_FILE"
}

# Run main function
main "$@"
