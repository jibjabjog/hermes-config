#!/bin/bash
# freerouter_failover.sh — Wraps freerouter.py with automatic local-llama fallback
# Daily OpenRouter model rotation. Hermes' LOCAL FALLBACK (gemma-4-E2B behind
# llama-router.service, :8080) is pinned in config.yaml and kept alive/verified by
# fallback_guard.sh — this script no longer switches it, and if freerouter fails
# the previous model selection stays in place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
LOG_FILE="$HERMES_HOME/logs/freerouter_failover.log"
FAILOVER_STATE="$HERMES_HOME/failover_state.json"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

# 2026-09-24: qwen35-tiny (:45072) has been retired. The single local failover is
# now "inky" (gemma-4-E2B) on the router at :8080, kept alive/warm/honest by
# fallback_guard.sh + fallback_warm.sh — this script does not manage it. The old
# check_qwen35_tiny()/ensure_qwen35_tiny() helpers were removed with the model.

# fallback_model is pinned to inky = gemma-4-E2B (llama-router :8080) since
# 2026-09-18; fallback_guard.sh keeps it running and detects config drift. All
# earlier tiers (qwen35-fast/4B and qwen35-tiny) are fully retired — inky is now
# the ONLY local failover, and also serves the auxiliary model roles. These
# functions only track/report Freerouter's own OpenRouter-availability state;
# they deliberately never touch fallback_model.
switch_to_local() {
    log "Freerouter unavailable — keeping the previous model selection; fallback_model stays pinned to local gemma-4-E2B (:8080), nothing to switch"
    echo "{\"active\":\"local\",\"timestamp\":\"$TIMESTAMP\"}" > "$FAILOVER_STATE"
    return 0
}

switch_to_openrouter() {
    log "Freerouter recovered — fallback_model stays pinned to local gemma-4-E2B (:8080); this only affects Freerouter's own model rotation, not the fallback tier"
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

# The local failover (inky @ :8080) is owned by fallback_guard.sh, not this
# script — nothing to ensure here anymore.

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
    log "Freerouter failed — previous OpenRouter selection kept; local fallback is gemma-4-E2B on :8080"

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
    send_telegram_update "⚠️ Freerouter failed (exit $EXIT_CODE) — model rotation skipped, previous selection kept. Local fallback (gemma-4-E2B :8080) unchanged."

    log "Freerouter run failed; local fallback (gemma-4-E2B) unchanged"
    exit 1
fi
