#!/bin/bash
# Portfolio News Checker v2.0 - Complete Rebuild
# Monitors Chris's holdings for breaking news
# Two modes: "breaking" (every 30 min) and "daily" (7 AM digest)

set -euo pipefail

# === Configuration ===
LOG_FILE="/home/pi/.openclaw/workspace/logs/portfolio_news.log"
TOKEN_FILE="/home/pi/.openclaw/workspace/memory/telegram_bot_token.txt"
STATE_FILE="/home/pi/.openclaw/workspace/memory/portfolio_news_state.json"
CHAT_ID="720036884"

# Load API key from environment or config file
BRAVE_API_KEY="${BRAVE_API_KEY:-}"
if [[ -z "$BRAVE_API_KEY" ]] && [[ -f "$HOME/.openclaw/openclaw.json" ]]; then
    BRAVE_API_KEY=$(jq -r '.secrets.brave_news_api_key // empty' "$HOME/.openclaw/openclaw.json" 2>/dev/null || echo "")
fi

# Chris's portfolio holdings
TICKERS=("PM" "INTC" "EPOL" "XLE" "AMZN" "VALE" "RTX" "OSBC")
CRYPTO=("BTC")

# Mode: "breaking" or "daily"
MODE="${1:-daily}"

# === Logging ===
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
log() { echo "[$TIMESTAMP] $*" >> "$LOG_FILE"; }
log_error() { echo "[$TIMESTAMP] ERROR: $*" >> "$LOG_FILE" >&2; }

# === Dependency Check ===
check_deps() {
    local missing=()
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

# === Validate Configuration ===
validate_config() {
    if [[ -z "$BRAVE_API_KEY" ]]; then
        log_error "Brave API key not configured"
        exit 1
    fi
    if [[ ! -f "$TOKEN_FILE" ]]; then
        log_error "Telegram token file not found: $TOKEN_FILE"
        exit 1
    fi
}

# === Initialize State File ===
init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << 'EOF'
{
    "last_check": "",
    "seen_urls": [],
    "failure_count": 0
}
EOF
    fi
}

# === Relevance Scoring ===
# Returns score 0-5 based on news importance
calculate_relevance_score() {
    local title="$1"
    local score=0
    
    # Convert to lowercase for matching
    local title_lower=$(echo "$title" | tr '[:upper:]' '[:lower:]')
    
    # CRITICAL keywords (+5 points)
    # Earnings, M&A, regulatory actions, major executive changes
    if echo "$title_lower" | grep -qE "earnings|eps|revenue|guidance|beat|miss|acquisition|merger|buyout|takeover|lawsuit|sec|doj|investigation|bankruptcy|ceo.*resigns|ceo.*fired|cfo.*resigns|cfo.*fired"; then
        score=$((score + 5))
    fi
    
    # Dividend keywords (critical for income stocks like PM, VALE)
    if echo "$title_lower" | grep -qE "dividend.*cut|dividend.*increase|dividend.*raise|payout.*ratio|dividend.*yield"; then
        score=$((score + 5))
    fi
    if echo "$title_lower" | grep -qE "(earnings|eps|revenue|guidance|beat|miss)"; then
        score=$((score + 5))
    fi
    
    # HIGH impact keywords (+4 points)
    if echo "$title_lower" | grep -qE "(acquisition|merger|buyout|takeover|lawsuit|sec|doj|investigation|bankruptcy)"; then
        score=$((score + 4))
    fi
    
    # MEDIUM impact keywords (+3 points)
    if echo "$title_lower" | grep -qE "(upgrade|downgrade|target|price target|analyst|ceo|cfo|executive|resigns|fired)"; then
        score=$((score + 3))
    fi
    
    # Sector events (+2 points)
    if echo "$title_lower" | grep -qE "(fed|interest rate|inflation|opec|oil price|supply chain)"; then
        score=$((score + 2))
    fi
    
    echo "$score"
}

# === Age Parsing ===
# Returns 0 if news is recent enough, 1 if too old
is_recent() {
    local age="$1"
    local max_hours="$2"
    
    # Extract number and unit
    local num=$(echo "$age" | grep -oE '[0-9]+' | head -1 || echo "999")
    local unit=$(echo "$age" | grep -oE '(hour|hours|min|mins|day|days|now|yesterday)' | head -1 || echo "days")
    
    # Convert to hours
    local age_hours=999
    case "$unit" in
        min|mins) age_hours=$((num / 60)) ;;
        hour|hours) age_hours="$num" ;;
        day|days) age_hours=$((num * 24)) ;;
        now|yesterday) age_hours=0 ;;
    esac
    
    if [[ "$age_hours" -le "$max_hours" ]]; then
        return 0  # Recent enough
    else
        return 1  # Too old
    fi
}

# === URL Deduplication ===
# Returns 0 if URL is new, 1 if already seen
is_new_url() {
    local url="$1"
    local url_hash=$(echo "$url" | md5sum | cut -d' ' -f1)
    
    # Check if URL is in seen list
    if jq -e ".seen_urls | index(\"$url_hash\")" "$STATE_FILE" >/dev/null 2>&1; then
        return 1  # Already seen
    fi
    
    return 0  # New URL
}

# === Mark URL as Seen ===
mark_url_seen() {
    local url="$1"
    local url_hash=$(echo "$url" | md5sum | cut -d' ' -f1)
    
    # Add to seen_urls array (keep last 1000)
    local temp_file=$(mktemp)
    jq --arg hash "$url_hash" '.seen_urls = ((.seen_urls + [$hash]) | .[-1000:])' "$STATE_FILE" > "$temp_file" && mv "$temp_file" "$STATE_FILE"
}

# === Fetch News with Retry ===
fetch_news() {
    local query="$1"
    local max_retries=3
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        local result
        if result=$(curl -s --max-time 15 \
            -H "x-subscription-token: $BRAVE_API_KEY" \
            "https://api.search.brave.com/res/v1/news/search?q=${query}&count=5" 2>/dev/null); then
            
            # Validate JSON response
            if echo "$result" | jq -e '.results' >/dev/null 2>&1; then
                echo "$result"
                return 0
            fi
        fi
        
        retry=$((retry + 1))
        log "WARNING: API attempt $retry/$max_retries failed for query: $query"
        sleep $((retry * 2))  # Exponential backoff
    done
    
    log_error "All API attempts failed for query: $query"
    return 1
}

# === Process News Results ===
process_results() {
    local result="$1"
    local category="$2"
    local icon="$3"
    local max_age_hours="$4"
    local min_score="$5"
    
    local count=$(echo "$result" | jq '.results | length' 2>/dev/null || echo "0")
    local news_items=""
    
    for i in 0 1 2; do
        [[ $i -ge $count ]] && break
        
        local title=$(echo "$result" | jq -r ".results[$i].title // empty")
        local age=$(echo "$result" | jq -r ".results[$i].age // empty")
        local url=$(echo "$result" | jq -r ".results[$i].url // empty")
        
        [[ -z "$title" || -z "$url" ]] && continue
        
        # Check if URL already seen
        if ! is_new_url "$url"; then
            log "Skipping duplicate: $url"
            continue
        fi
        
        # Check age
        if ! is_recent "$age" "$max_age_hours"; then
            log "Skipping old news ($age): $title"
            continue
        fi
        
        # Calculate relevance score
        local score=$(calculate_relevance_score "$title")
        if [[ "$score" -lt "$min_score" ]]; then
            log "Skipping low relevance (score=$score): $title"
            continue
        fi
        
        # Add to news items
        news_items="${news_items}${icon} ${title}%0A"
        news_items="${news_items}   Source: $(echo "$url" | sed 's|https://||; s|/.*||') | $age%0A"
        news_items="${news_items}   🔗 $url%0A%0A"
        
        # Mark as seen
        mark_url_seen "$url"
        log "Added news: $title (score=$score, age=$age)"
    done
    
    echo "$news_items"
}

# === Send Telegram Message ===
send_telegram() {
    local message="$1"
    local max_retries=3
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        local response
        if response=$(curl -s -X POST "https://api.telegram.org/bot$(cat "$TOKEN_FILE")/sendMessage" \
            -d "chat_id=$CHAT_ID" \
            -d "text=$message" \
            -d "parse_mode=Markdown" 2>/dev/null); then
            
            if echo "$response" | jq -r '.ok' 2>/dev/null | grep -q "true"; then
                log "✅ Telegram message sent successfully"
                # Reset failure count on success
                jq '.failure_count = 0' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                return 0
            fi
        fi
        
        retry=$((retry + 1))
        log "WARNING: Telegram send attempt $retry/$max_retries failed"
        sleep 2
    done
    
    log_error "Failed to send Telegram message after $max_retries attempts"
    
    # Increment failure count
    local fail_count=$(jq -r '.failure_count // 0' "$STATE_FILE")
    fail_count=$((fail_count + 1))
    jq --argjson count "$fail_count" '.failure_count = $count' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    
    return 1
}

# === Main Execution ===
main() {
    log "=== Starting portfolio news check (mode: $MODE) ==="
    
    # Initialize
    check_deps
    validate_config
    init_state
    
    # Update last check time
    local check_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
    jq --arg time "$check_time" '.last_check = $time' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    
    # Set thresholds based on mode
    local max_age_hours=24
    local min_score=2
    local header_emoji="📊"
    local header_text="Portfolio Daily Check"
    
    if [[ "$MODE" == "breaking" ]]; then
        max_age_hours=4  # Extended from 2 to 4 hours to catch delayed coverage
        min_score=4
        header_emoji="🚨"
        header_text="BREAKING: Portfolio Alert"
    fi
    
    # Collect news
    local all_news=""
    local news_found=false
    
    # Check individual tickers
    log "Checking ticker-specific news..."
    for ticker in "${TICKERS[@]}"; do
        log "Checking $ticker..."
        local result
        if result=$(fetch_news "$ticker%20stock%20news%20earnings"); then
            local news=$(process_results "$result" "$ticker" "📈" "$max_age_hours" "$min_score")
            if [[ -n "$news" ]]; then
                all_news="${all_news}*${ticker}:*%0A${news}"
                news_found=true
            fi
        fi
    done
    
    # Check crypto
    log "Checking crypto news..."
    for crypto in "${CRYPTO[@]}"; do
        log "Checking $crypto..."
        local result
        if result=$(fetch_news "$crypto%20bitcoin%20ethereum%20cryptocurrency%20news"); then
            local news=$(process_results "$result" "$crypto" "₿" "$max_age_hours" "$min_score")
            if [[ -n "$news" ]]; then
                all_news="${all_news}*${crypto}:*%0A${news}"
                news_found=true
            fi
        fi
    done
    
    # Check major market/geopolitical events (higher threshold)
    log "Checking geopolitical/market news..."
    local geo_queries=(
        "stock%20market%20war%20iran%20israel%20middle%20east"
        "fed%20interest%20rate%20decision%20inflation"
        "oil%20prices%20opec%20energy%20crisis"
    )
    
    for query in "${geo_queries[@]}"; do
        local result
        if result=$(fetch_news "$query"); then
            local news=$(process_results "$result" "MARKET" "🌍" "$max_age_hours" "$((min_score + 1))")
            if [[ -n "$news" ]]; then
                all_news="${all_news}${news}"
                news_found=true
            fi
        fi
    done
    
    # Build and send message
    if [[ "$news_found" == true ]]; then
        log "BREAKING NEWS FOUND - sending alert"
        
        local message="${header_emoji} *${header_text}*%0A%0A"
        message="${message}⏰ *Last checked:* ${check_time}%0A%0A"
        message="${message}${all_news}"
        message="${message}%0A---%0A"
        message="${message}_Powered by Gus 🦞_"
        
        send_telegram "$message"
    else
        log "No breaking news found"
        
        if [[ "$MODE" == "daily" ]]; then
            # Send all-clear for daily check
            local message="📊 *Portfolio Daily Check*%0A%0A"
            message="${message}All quiet on the portfolio front. No breaking news in the last 24 hours.%0A%0A"
            message="${message}*Holdings monitored:*%0A"
            message="${message}PM, INTC, EPOL, XLE, AMZN, VALE, RTX, OSBC, BTC%0A%0A"
            message="${message}_Powered by Gus 🦞_"
            
            send_telegram "$message"
        fi
        # Breaking mode: don't send if no news (avoid spam)
    fi
    
    log "=== Portfolio news check complete ==="
}

# Run main function
main "$@"
