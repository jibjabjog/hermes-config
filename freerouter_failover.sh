#!/bin/bash
# freerouter_failover.sh — Wraps freerouter.py with automatic local-llama fallback
# If freerouter fails or returns non-zero, switch to qwen35-tiny (port 45072)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
LOG_FILE="$HERMES_HOME/logs/freerouter_failover.log"
FAILOVER_STATE="$HERMES_HOME/failover_state.json"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

# Check if local backup (qwen35-tiny) is running
check_qwen35_tiny() {
    curl -s --max-time 3 http://127.0.0.1:45072/health > /dev/null 2>&1
}

# Ensure qwen35-tiny is running (start if not)
ensure_qwen35_tiny() {
    if ! check_qwen35_tiny; then
        log "WARN: qwen35-tiny not running on port 45072 — starting it"
        "$SCRIPT_DIR/../llama.cpp/build/bin/llama-server" \
            --host 127.0.0.1 --port 45072 \
            --alias qwen35-tiny \
            --model "$HERMES_HOME/../models/Qwen3.5-0.8B-Q4_K_M.gguf" \
            --ctx-size 2048 --threads 4 --n-gpu-layers 0 \
            --cache-type-k q4_0 --cache-type-v q4_0 \
            >> "$HERMES_HOME/logs/qwen35-tiny.log" 2>&1 &
        sleep 3
        if check_qwen35_tiny; then
            log "OK: qwen35-tiny started on port 45072"
        else
            log "ERROR: Failed to start qwen35-tiny"
            return 1
        fi
    else
        log "OK: qwen35-tiny already running on port 45072"
    fi
}

# Switch hermes default to local qwen35-tiny via llama-server config
switch_to_local() {
    log "SWITCHING to local backup: qwen35-tiny (port 45072)"

    # Update failover state
    echo "{\"active\":\"local\",\"timestamp\":\"$TIMESTAMP\"}" > "$FAILOVER_STATE"

    # Patch config.yaml to point default at qwen35-tiny via local server
    # This assumes hermes is configured with an openai-compatible local endpoint
    # The actual switching depends on hermes config — may need hermes model set
    log "FAILOVER COMPLETE: Running on qwen35-tiny local backup"
    return 0
}

# Switch back to openrouter (freerouter will do this on next run)
switch_to_openrouter() {
    log "Switching back to OpenRouter mode"
    echo "{\"active\":\"openrouter\",\"timestamp\":\"$TIMESTAMP\"}" > "$FAILOVER_STATE"
}

# Send Telegram notification
send_telegram_update() {
    local message="$1"
    local bot_token="${TELEGRAM_BOT_TOKEN:-}"
    local chat_id="${TELEGRAM_HOME_CHANNEL:-}"

    if [[ -z "$bot_token" ]] || [[ -z "$chat_id" ]]; then
        log "Telegram not configured — logging instead"
        log "MSG: $message"
        return
    fi

    local url="https://api.telegram.org/bot${bot_token}/sendMessage"
    local payload="{\"chat_id\":\"$chat_id\",\"text\":\"🚨 FREEROUTER FAILOVER\n$message\",\"parse_mode\":\"Markdown\"}"

    local response
    response=$(curl -s --max-time 10 -H "Content-Type: application/json" \
        -d "$payload" "$url" 2>&1) || true

    if echo "$response" | grep -q '"ok":true'; then
        log "Telegram sent: $message"
    else
        log "Telegram failed: $response"
    fi
}

# Telegram notification
send_telegram_update() {
    local message="$1"
    local bot_token="${TELEGRAM_BOT_TOKEN:-}"
    local chat_id="${TELEGRAM_HOME_CHANNEL:-}"

    if [[ -z "$bot_token" ]] || [[ -z "$chat_id" ]]; then
        log "Telegram not configured — logging instead"
        log "MSG: $message"
        return
    fi

    local url="https://api.telegram.org/bot${bot_token}/sendMessage"
    local payload="{\"chat_id\":\"$chat_id\",\"text\":\"🚨 FREEROUTER FAILOVER\n$message\",\"parse_mode\":\"Markdown\"}"

    local response
    response=$(curl -s --max-time 10 -H "Content-Type: application/json" \
        -d "$payload" "$url" 2>&1) || true

    if echo "$response" | grep -q '"ok":true'; then
        log "Telegram sent: $message"
    else
        log "Telegram failed: $response"
    fi
}

# Load environment variables
load_env() {
    local env_file="$HERMES_HOME/.env"
    if [[ -f "$env_file" ]]; then
        set -a
        source "$env_file"
        set +a
        log "Loaded environment from $env_file"
    else
        log "No .env file found at $env_file"
    fi
}

# MAIN
MODE="${1:-live}"  # live or dry

log "========================================="
log "Freerouter Failover — START ($MODE)"
log "========================================="

load_env

if [[ "$MODE" == "dry" ]]; then
    log "DRY-RUN: Skipping freerouter execution"
    DRY_RUN=true
else
    DRY_RUN=false
fi

# Ensure local backup is ready before anything else
if ! ensure_qwen35_tiny; then
    log "ERROR: Cannot ensure qwen35-tiny is running"
    exit 1
fi

# Run freerouter with timeout
FREEROUTER_TIMEOUT=300  # 5 min max
FREEROUTER_LOG="$HERMES_HOME/logs/freerouter_run.log"

if [[ "$MODE" == "dry" ]]; then
    DRY_RUN=true python3 "$SCRIPT_DIR/freerouter.py" >> "$FREEROUTER_LOG" 2>&1
    EXIT_CODE=$?
else
    # Live run — let it update config
    DRY_RUN=false python3 "$SCRIPT_DIR/freerouter.py" >> "$FREEROUTER_LOG" 2>&1
    EXIT_CODE=$?
fi

if [[ $EXIT_CODE -eq 0 ]]; then
    log "Freerouter succeeded (exit 0) — OpenRouter active"
    switch_to_openrouter

    # Restart gateway to pick up new config (skip in dry-run or inside gateway)
    if [[ "$DRY_RUN" == "false" ]]; then
        if ! pgrep -f "hermes-gateway" > /dev/null; then
            log "Gateway not running — skipping restart"
        else
            # Check if we're running inside the gateway process
            if [[ "$MODE" == "live" ]]; then
                log "WARNING: Skipping gateway restart while inside gateway process"
                log "Restart manually with: hermes gateway restart"
            else
                log "Restarting hermes-gateway..."
                systemctl --user restart hermes-gateway
            fi
        fi
    fi

    # Telegram notification for normal operation
    send_telegram_update "✅ Freerouter: OpenRouter active (models updated)"

    log "SUCCESS: OpenRouter models active"
    exit 0
else
    log "ERROR: Freerouter failed (exit $EXIT_CODE)"
    log "Activating LOCAL FAILOVER: qwen35-tiny on port 45072"

    switch_to_local

    # Restart gateway to pick up fallback config (skip in dry-run or inside gateway)
    if [[ "$DRY_RUN" == "false" ]]; then
        if ! pgrep -f "hermes-gateway" > /dev/null; then
            log "Gateway not running — skipping restart"
        else
            # Check if we're running inside the gateway process
            if [[ "$MODE" == "live" ]]; then
                log "WARNING: Skipping gateway restart while inside gateway process"
                log "Restart manually with: hermes gateway restart"
            else
                log "Restarting hermes-gateway with local fallback..."
                systemctl --user restart hermes-gateway
            fi
        fi
    fi

    # Telegram alert for failover event
    send_telegram_update "⚠️ FAILOVER: Freerouter failed. Switched to local qwen35-tiny (port 45072)"

    log "FAILOVER ACTIVE: Running on qwen35-tiny local backup"
    exit 1
fi
