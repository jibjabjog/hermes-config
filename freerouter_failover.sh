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

# Check if local backup (qwen35-tiny) is running
check_qwen35_tiny() {
    curl -s --max-time 3 http://127.0.0.1:45072/health > /dev/null 2>&1
}

# Ensure qwen35-tiny is running (start if not)
ensure_qwen35_tiny() {
    if ! check_qwen35_tiny; then
        log "WARN: qwen35-tiny not running on port 45072 — starting it"
        # NOTE: qwen35-tiny is now managed by the llama-qwen35-tiny.service systemd
        # --user unit (Restart=always), so this manual spawn is a last-resort fallback
        # only — it should not normally be needed. The path below was previously wrong
        # ("$SCRIPT_DIR/../llama.cpp/..." resolved to ~/.hermes/llama.cpp/..., which
        # doesn't exist) and silently failed every run; fixed to the real binary location.
        /home/huey/llama.cpp/build/bin/llama-server \
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

# fallback_model is pinned to gemma-4-E2B (llama-router :8080) since 2026-09-18;
# fallback_guard.sh (cron, every 5 min) keeps it running and detects config
# drift. The earlier tiers (qwen35-fast/4B; then qwen35-tiny) are retired as the
# fallback — qwen35-tiny ("Inky", :45072) still serves auxiliary tasks, which is
# why it is still checked below. These functions only track/report Freerouter's
# own OpenRouter-availability state; they deliberately never touch fallback_model.
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
