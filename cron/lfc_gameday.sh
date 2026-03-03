#!/bin/bash
# Liverpool FC Gameday Reminder - Phase 2 (Football-Data.org API)
# Checks for upcoming Liverpool matches using structured fixtures API
# Also reports scores from yesterday's matches
# Includes daily Liverpool news digest
# Free tier: 100 calls/day @ https://www.football-data.org/client/register

set -euo pipefail

# === Configuration ===
LOG_FILE="/home/pi/.openclaw/workspace/logs/lfc_gameday.log"
TOKEN_FILE="/home/pi/.openclaw/workspace/memory/telegram_bot_token.txt"
STATE_FILE="/home/pi/.openclaw/workspace/memory/lfc_gameday_state.json"
RATE_LIMIT_FILE="/home/pi/.openclaw/workspace/memory/lfc_api_rate_limit.json"
NEWS_STATE_FILE="/home/pi/.openclaw/workspace/memory/lfc_news_state.json"
CHAT_ID="720036884"
WORKSPACE="/home/pi/.openclaw/workspace"

# Constants
LIVERPOOL_TEAM_ID=64
API_BASE_URL="https://api.football-data.org/v4"
BRAVE_NEWS_URL="https://api.search.brave.com/res/v1/news/search"
MAX_RETRIES=3
CURL_TIMEOUT=15
DAILY_API_LIMIT=100
MAX_NEWS_STORIES=6
MAX_STORIES_PER_QUERY=2

# === Logging ===
log() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" >> "$LOG_FILE"
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
        log "❌ ERROR: Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

# === Initialize State File ===
init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << 'EOF'
{
    "last_notified_match_id": null,
    "last_reported_finished_match_id": null,
    "last_check": ""
}
EOF
        log "Initialized state file: $STATE_FILE"
    fi
    
    # Validate state file JSON
    if ! jq -e '.' "$STATE_FILE" >/dev/null 2>&1; then
        log "⚠️ State file corrupted, reinitializing..."
        cat > "$STATE_FILE" << 'EOF'
{
    "last_notified_match_id": null,
    "last_reported_finished_match_id": null,
    "last_check": ""
}
EOF
    fi
}

# === Initialize Rate Limit Tracking ===
init_rate_limit() {
    local today
    today=$(date '+%Y-%m-%d')
    
    if [[ ! -f "$RATE_LIMIT_FILE" ]]; then
        cat > "$RATE_LIMIT_FILE" << EOF
{
    "date": "$today",
    "calls_made": 0
}
EOF
    fi
    
    # Check if we need to reset the counter for a new day
    local stored_date
    stored_date=$(jq -r '.date // empty' "$RATE_LIMIT_FILE" 2>/dev/null)
    
    if [[ "$stored_date" != "$today" ]]; then
        log "Resetting daily API call counter (new day: $today)"
        cat > "$RATE_LIMIT_FILE" << EOF
{
    "date": "$today",
    "calls_made": 0
}
EOF
    fi
}

# === Check Rate Limit ===
check_rate_limit() {
    local calls_made
    calls_made=$(jq -r '.calls_made // 0' "$RATE_LIMIT_FILE" 2>/dev/null)
    
    if [[ "$calls_made" -ge "$DAILY_API_LIMIT" ]]; then
        log "❌ ERROR: Daily API rate limit reached ($calls_made/$DAILY_API_LIMIT calls)"
        log "   API calls will reset at midnight"
        exit 0
    fi
    
    log "API rate limit check: $calls_made/$DAILY_API_LIMIT calls used today"
}


# === Initialize News State File ===
init_news_state() {
    if [[ ! -f "$NEWS_STATE_FILE" ]]; then
        cat > "$NEWS_STATE_FILE" << 'EOF'
{
    "seen_urls": [],
    "last_check": ""
}
EOF
        log "Initialized news state file: $NEWS_STATE_FILE"
    fi
    
    # Validate news state file JSON
    if ! jq -e '.' "$NEWS_STATE_FILE" >/dev/null 2>&1; then
        log "⚠️ News state file corrupted, reinitializing..."
        cat > "$NEWS_STATE_FILE" << 'EOF'
{
    "seen_urls": [],
    "last_check": ""
}
EOF
    fi
}

# === URL Encoding ===
url_encode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos = 0 ; pos < strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="$c" ;;
            * ) printf -v o '%%%02X' "'$c" ;;
        esac
        encoded+="$o"
    done
    echo "$encoded"
}

# === URL Normalization for Deduplication ===
normalize_url() {
    local url="$1"
    # Lowercase, strip trailing slashes, remove query params for dedup
    echo "$url" | tr '[:upper:]' '[:lower:]' | sed -E 's|/+$||; s|\?.*$||'
}

# === Check if URL Already Seen ===
is_url_seen() {
    local url="$1"
    local normalized_url
    normalized_url=$(normalize_url "$url")
    local url_hash
    url_hash=$(echo "$normalized_url" | md5sum | cut -d' ' -f1)
    
    if jq -e --arg hash "$url_hash" '.seen_urls | index($hash)' "$NEWS_STATE_FILE" >/dev/null 2>&1; then
        return 0  # Already seen
    fi
    return 1  # New URL
}

# === Mark URL as Seen ===
mark_url_seen() {
    local url="$1"
    local normalized_url
    normalized_url=$(normalize_url "$url")
    local url_hash
    url_hash=$(echo "$normalized_url" | md5sum | cut -d' ' -f1)
    
    local temp_file
    temp_file=$(mktemp)
    jq --arg hash "$url_hash" '.seen_urls = ((.seen_urls + [$hash]) | .[-100:])' "$NEWS_STATE_FILE" > "$temp_file" && mv "$temp_file" "$NEWS_STATE_FILE"
}

# === Check if Age is Within 48 Hours ===
is_age_within_48h() {
    local age="$1"
    local now_epoch
    now_epoch=$(date +%s)
    local max_age=$((48 * 3600))  # 48 hours in seconds
    
    # Handle special cases
    [[ "$age" == "now" ]] && return 0
    [[ "$age" == "yesterday" ]] && return 0
    [[ "$age" == "today" ]] && return 0
    
    # Parse hours
    if [[ "$age" =~ ^([0-9]+)hour ]]; then
        local hours="${BASH_REMATCH[1]}"
        [[ "$hours" -le 48 ]] && return 0
        return 1
    fi
    
    # Parse minutes
    if [[ "$age" =~ ^([0-9]+)min ]]; then
        return 0  # Minutes are always within 48h
    fi
    
    # Parse days (only accept 1 day)
    if [[ "$age" =~ ^([0-9]+)day ]]; then
        local days="${BASH_REMATCH[1]}"
        [[ "$days" -le 1 ]] && return 0
        return 1
    fi
    
    # Unknown format - skip to be safe
    return 1
}

# === Extract Domain from URL ===
extract_domain() {
    local url="$1"
    echo "$url" | sed -E 's|^https?://||; s|/.*$||; s|\?.*$||'
}

# === Validate Brave API Key ===
validate_brave_api_key() {
    if [[ ! -f "$WORKSPACE/../openclaw.json" ]]; then
        log "⚠️ WARNING: openclaw.json not found, skipping news check"
        return 1
    fi
    
    if [[ -z "$BRAVE_API_KEY" ]] || [[ "$BRAVE_API_KEY" == "null" ]]; then
        log "⚠️ WARNING: BRAVE_API_KEY not configured, skipping news check"
        return 1
    fi
    
    return 0
}

# === Fetch Liverpool News with HTTP Status Check ===
fetch_liverpool_news() {
    local query="$1"
    local retry=0
    local news
    local http_code
    local temp_file
    
    # Validate inputs
    [[ -z "$query" ]] && { log "ERROR: Empty query provided to fetch_liverpool_news"; return 1; }
    [[ -z "$BRAVE_API_KEY" ]] && { log "ERROR: BRAVE_API_KEY not set"; return 1; }
    
    # URL encode the query
    local encoded_query
    encoded_query=$(url_encode "$query")
    
    temp_file=$(mktemp)
    
    while [[ $retry -lt $MAX_RETRIES ]]; do
        http_code=$(curl -s --max-time "$CURL_TIMEOUT" \
          --connect-timeout 5 \
          -o "$temp_file" \
          -w "%{http_code}" \
          -H "x-subscription-token: $BRAVE_API_KEY" \
          "${BRAVE_NEWS_URL}?q=${encoded_query}&count=${MAX_STORIES_PER_QUERY}" 2>/dev/null)
        
        # Check HTTP status code
        if [[ "$http_code" == "200" ]]; then
            news=$(cat "$temp_file")
            rm -f "$temp_file"
            
            # Validate JSON structure
            if echo "$news" | jq -e 'has("results")' >/dev/null 2>&1; then
                local result_count
                result_count=$(echo "$news" | jq 'try (.results | length) catch 0')
                if [[ "$result_count" -ge 0 ]]; then
                    echo "$news"
                    return 0
                fi
            fi
            log "WARNING: Invalid JSON structure from news API for query: $query"
        else
            log "⚠️ WARNING: News API returned HTTP $http_code for query: $query (attempt $((retry + 1)))"
        fi
        
        retry=$((retry + 1))
        [[ $retry -lt $MAX_RETRIES ]] && sleep $((retry * 2))
    done
    
    rm -f "$temp_file"
    log "ERROR: Failed to fetch news after $MAX_RETRIES attempts for query: $query"
    return 1
}

# === Get Emoji for Story Category ===
get_story_emoji() {
    local query="$1"
    case "$query" in
        *transfer*) echo "🔄" ;;
        *injur*) echo "🩹" ;;
        *klopp*|*manager*) echo "👔" ;;
        *tactic*) echo "📋" ;;
        *academ*) echo "🌱" ;;
        *) echo "📰" ;;
    esac
}

# === Process News Story ===
process_news_story() {
    local news_json="$1"
    local index="$2"
    local category="$3"
    
    local title age url source domain emoji
    title=$(echo "$news_json" | jq -r ".results[$index].title // empty")
    age=$(echo "$news_json" | jq -r ".results[$index].age // empty")
    url=$(echo "$news_json" | jq -r ".results[$index].url // empty")
    source=$(echo "$news_json" | jq -r ".results[$index].description // empty" | head -c 150)
    
    # Validate required fields
    [[ -z "$title" || -z "$url" ]] && return 1
    
    # Check if URL already seen
    is_url_seen "$url" && return 1
    
    # Check age (within 48 hours)
    is_age_within_48h "$age" || return 1
    
    # Get emoji for category
    emoji=$(get_story_emoji "$category")
    
    # Extract domain
    domain=$(extract_domain "$url")
    
    # Return formatted story
    echo "• ${emoji} *${title}*"
    echo "  [${domain}](${url}) | _${age}_"
    echo ""
    
    # Mark as seen
    mark_url_seen "$url"
    log "Added news story: $title (${category})"
    
    return 0
}

# === Check Liverpool News ===
check_liverpool_news() {
    log "Checking for Liverpool FC news..."
    
    # Validate Brave API key
    if ! validate_brave_api_key; then
        log "Skipping news check (no API key)"
        return 0
    fi
    
    # Search queries with categories for comprehensive coverage
    local -a queries=(
        "Liverpool FC news:general"
        "Liverpool FC transfers:transfers"
        "Liverpool FC injuries:injuries"
        "Liverpool FC Slot:manager"
        "Liverpool FC tactics:tactics"
        "Liverpool FC academy:academy"
    )
    
    local -a news_items=()
    local total_stories=0
    local stories_by_category=()
    
    for query_entry in "${queries[@]}"; do
        [[ $total_stories -ge $MAX_NEWS_STORIES ]] && break
        
        local query="${query_entry%%:*}"
        local category="${query_entry##*:}"
        local category_count=0
        
        local news
        if news=$(fetch_liverpool_news "$query"); then
            local count
            count=$(echo "$news" | jq '.results | length')
            
            for ((i=0; i<count && category_count<MAX_STORIES_PER_QUERY && total_stories<MAX_NEWS_STORIES; i++)); do
                local story
                story=$(process_news_story "$news" "$i" "$category")
                
                if [[ -n "$story" ]]; then
                    news_items+=("$story")
                    ((category_count++))
                    ((total_stories++))
                fi
            done
        fi
    done
    
    if [[ ${#news_items[@]} -gt 0 ]]; then
        # Build Telegram message
        local message
        message="📰🦁🔴 *LIVERPOOL NEWS DIGEST*%0A%0A"
        message="${message}_Top stories from the last 48 hours:%0A%0A"
        
        for item in "${news_items[@]}"; do
            # Escape special characters for Telegram Markdown
            local escaped_item
            escaped_item=$(echo "$item" | sed 's/_/\\_/g; s/*/\\*/g; s/`/\\`/g')
            message="${message}${escaped_item}%0A"
        done
        
        message="${message}%0A🔴 *YNWA*"
        
        # Send to Telegram
        if send_telegram_with_retry "$message"; then
            log "✅ Sent news digest (${total_stories} stories)"
            
            # Update news state
            local temp_file
            temp_file=$(mktemp)
            jq --arg check_time "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
              '.last_check = $check_time' "$NEWS_STATE_FILE" > "$temp_file" && mv "$temp_file" "$NEWS_STATE_FILE"
        else
            log "❌ ERROR: Failed to send news digest"
            return 1
        fi
    else
        log "No new Liverpool news found in last 48 hours"
    fi
    
    return 0
}

# === Validate Telegram Token ===
validate_telegram_token() {
    if [[ ! -f "$TOKEN_FILE" ]]; then
        log "❌ ERROR: Telegram token file not found: $TOKEN_FILE"
        exit 1
    fi
    
    if [[ ! -s "$TOKEN_FILE" ]]; then
        log "❌ ERROR: Telegram token file is empty: $TOKEN_FILE"
        exit 1
    fi
}

# === Validate API Key ===
validate_api_key() {
    if [[ ! -f "$WORKSPACE/../openclaw.json" ]]; then
        log "❌ ERROR: openclaw.json not found at $WORKSPACE/../openclaw.json"
        exit 1
    fi
    
    if [[ -z "$FOOTBALL_DATA_API_KEY" ]] || [[ "$FOOTBALL_DATA_API_KEY" == "null" ]]; then
        log "❌ ERROR: FOOTBALL_DATA_API_KEY is empty or null in config"
        log "   Get free API key at: https://www.football-data.org/client/register"
        exit 1
    fi
    
    # Basic key format validation (should be 32+ hex chars)
    if [[ ! "$FOOTBALL_DATA_API_KEY" =~ ^[a-fA-F0-9]{32,}$ ]]; then
        log "⚠️ WARNING: API key format looks unusual (expected 32+ hex chars)"
    fi
}

# === Fetch Fixtures with Retry ===
fetch_fixtures_with_retry() {
    local status="$1"
    local retry=0
    local fixtures
    
    while [[ $retry -lt $MAX_RETRIES ]]; do
        if fixtures=$(curl -s --max-time "$CURL_TIMEOUT" \
          -H "X-Auth-Token: $FOOTBALL_DATA_API_KEY" \
          "$API_BASE_URL/teams/$LIVERPOOL_TEAM_ID/matches?status=$status&limit=5" 2>/dev/null); then
            
            # Check for rate limit response
            if echo "$fixtures" | jq -e '.code == "RATE_LIMIT_EXCEEDED"' >/dev/null 2>&1; then
                log "❌ ERROR: API returned rate limit exceeded"
                return 1
            fi
            
            # Validate JSON response
            if echo "$fixtures" | jq -e '.matches' >/dev/null 2>&1; then
                echo "$fixtures"
                return 0
            fi
        fi
        
        retry=$((retry + 1))
        log "⚠️ WARNING: API attempt $retry/$MAX_RETRIES failed for status=$status"
        sleep $((retry * 2))
    done
    
    log "❌ ERROR: All $MAX_RETRIES API attempts failed for status=$status"
    return 1
}

# === Convert Date to Local Time ===
convert_date_to_local() {
    local utc_date="$1"
    local converted_date
    
    # Validate date format (ISO 8601)
    if [[ ! "$utc_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
        log "⚠️ WARNING: Invalid date format from API: $utc_date"
        echo "$utc_date"
        return
    fi
    
    if converted_date=$(date -d "$utc_date" '+%A, %B %d at %I:%M %p %Z' 2>/dev/null); then
        echo "$converted_date"
    else
        log "⚠️ WARNING: Could not convert date: $utc_date, using original"
        echo "$utc_date"
    fi
}

# === Send Telegram Message with Retry ===
send_telegram_with_retry() {
    local message="$1"
    local retry=0
    local response
    
    while [[ $retry -lt $MAX_RETRIES ]]; do
        if response=$(curl -s -X POST "https://api.telegram.org/bot$(cat "$TOKEN_FILE")/sendMessage" \
          -d "chat_id=$CHAT_ID" \
          -d "text=$message" \
          -d "parse_mode=Markdown" 2>/dev/null); then
            
            if echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
                if echo "$response" | jq -e '.result.message_id' >/dev/null 2>&1; then
                    log "✅ Telegram message sent successfully (message_id: $(echo "$response" | jq -r '.result.message_id'))"
                    return 0
                fi
            fi
        fi
        
        retry=$((retry + 1))
        log "⚠️ WARNING: Telegram send attempt $retry/$MAX_RETRIES failed"
        sleep 2
    done
    
    log "❌ ERROR: Failed to send Telegram message after $MAX_RETRIES attempts"
    log "Response: $response"
    return 1
}

# === Report Yesterday's Match Result ===
report_yesterday_result() {
    log "Checking for yesterday's match result..."
    
    local fixtures
    if ! fixtures=$(fetch_fixtures_with_retry "FINISHED"); then
        log "❌ ERROR: Failed to fetch finished matches"
        return 1
    fi
    
    # Get matches from yesterday
    local yesterday
    yesterday=$(date -d "yesterday" '+%Y-%m-%d')
    
    local match
    match=$(echo "$fixtures" | jq -r --arg date "$yesterday" '.matches[] | select(.utcDate | startswith($date))' | head -1)
    
    if [[ -z "$match" ]]; then
        log "No Liverpool match found from yesterday ($yesterday)"
        return 0
    fi
    
    # Extract match details
    local match_id home_team away_team home_score away_score competition match_date_utc
    match_id=$(echo "$match" | jq -r '.id')
    home_team=$(echo "$match" | jq -r '.homeTeam.name')
    away_team=$(echo "$match" | jq -r '.awayTeam.name')
    home_score=$(echo "$match" | jq -r '.score.fullTime.home // 0')
    away_score=$(echo "$match" | jq -r '.score.fullTime.away // 0')
    competition=$(echo "$match" | jq -r '.competition.name')
    match_date_utc=$(echo "$match" | jq -r '.utcDate')
    
    # Check if we already reported this match
    local last_reported
    last_reported=$(jq -r '.last_reported_finished_match_id // null' "$STATE_FILE")
    
    if [[ "$last_reported" == "$match_id" ]]; then
        log "✅ Already reported this finished match (ID: $match_id)"
        return 0
    fi
    
    # Determine if Liverpool won/lost/drew
    local result_emoji result_text
    if [[ "$home_team" == "Liverpool FC" ]]; then
        if [[ "$home_score" -gt "$away_score" ]]; then
            result_emoji="🔴"
            result_text="WIN"
        elif [[ "$home_score" -lt "$away_score" ]]; then
            result_emoji="😞"
            result_text="LOSS"
        else
            result_emoji="🤝"
            result_text="DRAW"
        fi
        result_text="Liverpool $home_score-$away_score $away_team ($result_text)"
    else
        if [[ "$away_score" -gt "$home_score" ]]; then
            result_emoji="🔴"
            result_text="WIN"
        elif [[ "$away_score" -lt "$home_score" ]]; then
            result_emoji="😞"
            result_text="LOSS"
        else
            result_emoji="🤝"
            result_text="DRAW"
        fi
        result_text="$home_team $home_score-$away_score Liverpool ($result_text)"
    fi
    
    # Build Telegram message
    local message
    message="⚽🦁🔴 *YESTERDAY'S RESULT*%0A%0A"
    message="${message}*${result_text}*%0A"
    message="${message}*Competition:* ${competition}%0A"
    message="${message}*Date:* $(convert_date_to_local "$match_date_utc")%0A%0A"
    message="${message}🔴 *YNWA*"
    
    # Send to Telegram
    if ! send_telegram_with_retry "$message"; then
        log "❌ ERROR: Failed to send result notification"
        return 1
    fi
    
    # Update state file
    {
        flock -x 200
        local temp_file
        temp_file=$(mktemp)
        jq --arg match_id "$match_id" '.last_reported_finished_match_id = $match_id' \
          "$STATE_FILE" > "$temp_file" && mv "$temp_file" "$STATE_FILE"
        log "✅ State file updated (reported match_id: $match_id)"
    } 200>"$STATE_FILE.lock"
    
    log "✅ Reported result: $result_text"
    return 0
}

# === Check Upcoming Fixtures ===
check_upcoming_fixtures() {
    log "Checking for upcoming Liverpool fixtures..."
    
    local fixtures
    if ! fixtures=$(fetch_fixtures_with_retry "SCHEDULED"); then
        log "❌ ERROR: Failed to fetch scheduled fixtures"
        return 1
    fi
    
    # Get the next upcoming match
    local next_match
    next_match=$(echo "$fixtures" | jq -r '.matches | sort_by(.utcDate) | .[0] // empty')
    
    if [[ -z "$next_match" ]]; then
        log "No upcoming Liverpool fixtures found"
        return 0
    fi
    
    # Extract match details
    local match_id home_team away_team competition venue opponent match_date_utc match_date_local
    match_id=$(echo "$next_match" | jq -r '.id')
    match_date_utc=$(echo "$next_match" | jq -r '.utcDate')
    home_team=$(echo "$next_match" | jq -r '.homeTeam.name')
    away_team=$(echo "$next_match" | jq -r '.awayTeam.name')
    competition=$(echo "$next_match" | jq -r '.competition.name')
    
    # Determine opponent and venue
    if [[ "$home_team" == "Liverpool FC" ]]; then
        opponent="$away_team"
        venue="Anfield (Home)"
    else
        opponent="$home_team"
        # Get stadium name for away matches if available
        local stadium
        stadium=$(echo "$next_match" | jq -r '.venue // "Away"')
        venue="$stadium (Away)"
    fi
    
    # Convert date to local timezone
    match_date_local=$(convert_date_to_local "$match_date_utc")
    
    # Check if we already notified about this match
    local last_notified
    last_notified=$(jq -r '.last_notified_match_id // null' "$STATE_FILE")
    
    if [[ "$last_notified" == "$match_id" ]]; then
        log "✅ Already notified about this match (ID: $match_id)"
        return 0
    fi
    
    # Build Telegram message
    local message
    message="⚽🦁🔴 *UPCOMING MATCH ALERT!*%0A%0A"
    message="${message}*Opponent:* ${opponent}%0A"
    message="${message}*Competition:* ${competition}%0A"
    message="${message}*Kickoff:* ${match_date_local}%0A"
    message="${message}*Venue:* ${venue}%0A%0A"
    message="${message}📺 *Watch:* Check ESPN+ / Paramount+%0A%0A"
    message="${message}🔴 *YNWA*"
    
    # Send to Telegram
    if ! send_telegram_with_retry "$message"; then
        log "❌ ERROR: Failed to send upcoming match notification"
        return 1
    fi
    
    # Update state file
    {
        flock -x 200
        local temp_file
        temp_file=$(mktemp)
        jq --arg match_id "$match_id" --arg check_time "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
          '.last_notified_match_id = $match_id | .last_check = $check_time' \
          "$STATE_FILE" > "$temp_file" && mv "$temp_file" "$STATE_FILE"
        log "✅ State file updated (upcoming match_id: $match_id)"
    } 200>"$STATE_FILE.lock"
    
    log "✅ Sent upcoming match alert: Liverpool vs ${opponent} (${match_date_local})"
    return 0
}

# === Main Execution ===
main() {
    log "=== Starting Liverpool FC gameday check ==="
    
    # Initialize
    check_deps
    init_state
    init_rate_limit
    init_news_state
    
    # Check rate limit before making API calls
    check_rate_limit
    
    # Load API keys from config
    if ! FOOTBALL_DATA_API_KEY=$(jq -r '.secrets.football_data_api_key // empty' "$WORKSPACE/../openclaw.json" 2>/dev/null); then
        log "❌ ERROR: Could not parse JSON from config"
        exit 1
    fi
    
    if ! BRAVE_API_KEY=$(jq -r '.secrets.brave_news_api_key // empty' "$WORKSPACE/../openclaw.json" 2>/dev/null); then
        log "⚠️ WARNING: Could not load BRAVE_API_KEY from config"
    fi
    
    validate_api_key
    validate_telegram_token
    
    # 1. Report yesterday's result (if any)
    report_yesterday_result || true
    
    # 2. Check upcoming fixtures
    check_upcoming_fixtures || true
    
    # 3. Check Liverpool news digest
    check_liverpool_news || true
    
    log "=== Liverpool FC gameday check complete ==="
}

# Run main function
main "$@"
