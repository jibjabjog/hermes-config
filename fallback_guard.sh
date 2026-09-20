#!/bin/bash
# fallback_guard.sh — keeps Hermes' local fallback (gemma-4-E2B behind
# llama-router.service) alive AND honest.
#
# Why this exists: on 2026-09-15 the fallback was found to have silently
# pointed at a dead port for weeks (see jibjabjog/hermes-config, commit
# df0a790). Nothing was checking that it actually WORKED. So this does not
# just test "is the port open" — every run:
#   1. makes sure the router service is running (starts it if not)
#   2. proves the model really answers a completion (loads it if needed;
#      restarts the router once if it doesn't)
#   3. checks config.yaml still points the fallback at it (drift check)
#   4. keeps the prompt cache warm for the real Telegram prompt (fallback_warm.sh)
#
# Output contract (Hermes no-agent cron job): EMPTY stdout = healthy and
# silent; anything printed is delivered to Telegram. So it only speaks on a
# state change (problem / self-healed / recovered), plus a reminder every
# FALLBACK_REALERT_SECS while a problem persists. Details always go to the log.
#
#   fallback_guard.sh          # normal (cron): silent when healthy
#   fallback_guard.sh -v       # verbose: always print the status line
#
# Never enables units or edits config.yaml (set FALLBACK_AUTOFIX_DRIFT=1 to
# let it repair a drifted fallback_model via set_fallback_model.py).
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CONFIG="${FALLBACK_CONFIG:-$HERMES_HOME/config.yaml}"
LOG="$HERMES_HOME/logs/fallback_guard.log"
STATE="${FALLBACK_STATE:-$HERMES_HOME/fallback_guard.state}"
LOCK="${FALLBACK_LOCK:-$HERMES_HOME/.fallback_guard.lock}"
UNIT="${FALLBACK_UNIT:-llama-router.service}"
EXPECT_MODEL="${FALLBACK_EXPECT_MODEL:-google/gemma-4-E2B-it-qat-q4_0-gguf:IT}"
EXPECT_URL="${FALLBACK_EXPECT_URL:-http://127.0.0.1:8080/v1}"
PROBE_TIMEOUT="${FALLBACK_PROBE_TIMEOUT:-180}"      # cold model load ~16 s; allow slack
START_WAIT="${FALLBACK_START_WAIT:-90}"
REALERT_SECS="${FALLBACK_REALERT_SECS:-21600}"      # 6 h
AUTOFIX_DRIFT="${FALLBACK_AUTOFIX_DRIFT:-0}"
VERBOSE=0; [[ "${1:-}" == "-v" ]] && VERBOSE=1

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"   # systemctl --user under cron
mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# One run at a time: a cold probe can take minutes.
exec 9>"$LOCK"
flock -n 9 || { log "another run holds the lock — skipping"; exit 0; }

# Keep the log bounded.
if [[ -f "$LOG" ]] && (( $(wc -l < "$LOG") > 2000 )); then
    tail -n 1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

BASE="${EXPECT_URL%/v1}"

healthy() { curl -sf -m 5 "$BASE/health" >/dev/null 2>&1; }

# "Busy" must mean the MODEL is working, not merely that a client is connected:
# a failover prefill can keep the model busy for many minutes (CPU prefill is
# ~20 tok/s against Hermes' ~20k-token prompt), and killing the client does NOT
# cancel it. While busy, a slow probe means "busy", never "down" — restarting
# the router mid-prefill would throw that work away exactly when it is needed.
PORT="${BASE##*:}"
active_conns() { ss -Htn state established "( sport = :${PORT} )" 2>/dev/null | wc -l; }

# The model's llama-server child, found by the alias the router gives it.
model_pid() { pgrep -f -- "--alias ${EXPECT_MODEL}" 2>/dev/null | head -1; }

# True if the model process used >=100% of one core over a 2 s window (idle ~0-5%).
model_working() {
    local pid t1 t2 hz
    pid="$(model_pid)"; [[ -n "$pid" ]] || return 1
    hz="$(getconf CLK_TCK)"
    t1="$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)" || return 1
    sleep 2
    t2="$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)" || return 1
    (( (t2 - t1) * 100 / (2 * hz) >= 100 ))
}
is_busy() { (( $(active_conns) > 0 )) || model_working; }

wait_healthy() {
    local i
    for ((i = 0; i < START_WAIT; i += 3)); do
        healthy && return 0
        sleep 3
    done
    return 1
}

# A real completion, not just an open port: the model must load and answer.
probe() {
    local resp
    resp="$(curl -s -m "$PROBE_TIMEOUT" "$EXPECT_URL/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg m "$EXPECT_MODEL" \
            '{model:$m, messages:[{role:"user",content:"ping"}], max_tokens:2}')")" || return 1
    echo "$resp" | jq -e '.choices[0].message' >/dev/null 2>&1
}

problems=()      # things still wrong at the end of the run
actions=()       # things this run fixed
status_detail=""

# ── 1. service running? ────────────────────────────────────────────────
unit_active="$(systemctl --user is-active "$UNIT" 2>/dev/null || true)"
unit_enabled="$(systemctl --user is-enabled "$UNIT" 2>/dev/null || true)"
if ! healthy; then
    log "router not healthy (unit: ${unit_active:-unknown}) — starting $UNIT"
    [[ "$unit_active" == "failed" ]] && systemctl --user reset-failed "$UNIT" 2>/dev/null
    systemctl --user start "$UNIT" 2>>"$LOG"
    if wait_healthy; then
        actions+=("router was down (unit ${unit_active:-unknown}); started it")
    else
        problems+=("router will not start: $UNIT is ${unit_active:-unknown} and $BASE/health does not answer (journalctl --user -u $UNIT)")
    fi
fi

# ── 2. does the model really answer? ───────────────────────────────────
busy=0
BUSY_MAX="${FALLBACK_BUSY_MAX_SECS:-3600}"   # longer than any plausible prefill
busy_since=0
[[ -f "$STATE" ]] && busy_since="$(grep -m1 '^busy_since=' "$STATE" | cut -d= -f2-)"
busy_since="${busy_since:-0}"
restart_model() {   # $1 = reason
    log "$1 — restarting $UNIT once"
    systemctl --user restart "$UNIT" 2>>"$LOG"
    if wait_healthy && probe; then
        actions+=("$1; restarted the router and the model answers again")
    else
        problems+=("model does not answer completions even after a restart ($EXPECT_MODEL at $EXPECT_URL)")
    fi
}
if healthy; then
    if is_busy; then
        busy=1
        [[ "$busy_since" == 0 ]] && busy_since="$(date +%s)"
        if (( $(date +%s) - busy_since > BUSY_MAX )); then
            restart_model "model has been busy for over $((BUSY_MAX / 60)) min (probably hung)"
            busy=0; busy_since=0
        else
            log "busy: model working / $(active_conns) connection(s) — skipping probe (a failover may be in progress)"
        fi
    else
        busy_since=0
        if ! probe; then
            if is_busy; then
                busy=1; busy_since="$(date +%s)"
                log "probe timed out but the model is now busy — treating as busy, not down"
            else
                restart_model "router was up but the model would not answer"
            fi
        fi
    fi
fi

# ── 2b. keep the prompt cache warm ─────────────────────────────────────
# Only when the model is healthy, idle and answering: a cold prefill of Hermes'
# real Telegram prompt takes ~17-20 min, so do it BEFORE a failover needs it.
# fallback_warm.sh is silent (log only) and detaches a cold prefill so this
# cron run stays short; 9>&- stops the detached job inheriting our lock.
if [[ "${FALLBACK_WARM:-1}" == "1" && $busy == 0 && ${#problems[@]} == 0 && -x "$HERMES_HOME/scripts/fallback_warm.sh" ]] && healthy; then
    "$HERMES_HOME/scripts/fallback_warm.sh" 9>&- || log "fallback_warm.sh exited non-zero"
fi

# Boot persistence: the guard won't enable units itself, but it will say so.
if [[ "$unit_enabled" != "enabled" ]]; then
    problems+=("$UNIT is not enabled at boot (state: ${unit_enabled:-unknown}) — run: systemctl --user enable $UNIT")
fi

# ── 3. config drift ────────────────────────────────────────────────────
cfg_model="$(awk '/^fallback_model:/{f=1;next} f&&/^[^ ]/{exit} f&&/^  model:/{print $2}' "$CONFIG" 2>/dev/null)"
cfg_url="$(awk '/^fallback_model:/{f=1;next} f&&/^[^ ]/{exit} f&&/^  base_url:/{print $2}' "$CONFIG" 2>/dev/null)"
if [[ "$cfg_model" != "$EXPECT_MODEL" || "$cfg_url" != "$EXPECT_URL" ]]; then
    if [[ "$AUTOFIX_DRIFT" == "1" && -x "$HERMES_HOME/scripts/set_fallback_model.py" ]]; then
        python3 "$HERMES_HOME/scripts/set_fallback_model.py" "$EXPECT_MODEL" "${EXPECT_URL##*:}" >/dev/null 2>&1 \
            && { actions+=("fallback_model had drifted to '${cfg_model:-none}' @ '${cfg_url:-none}'; repaired"); }
    else
        problems+=("config.yaml fallback_model has drifted: '${cfg_model:-none}' @ '${cfg_url:-none}' (expected '$EXPECT_MODEL' @ '$EXPECT_URL'). Fix: python3 ~/.hermes/scripts/set_fallback_model.py '$EXPECT_MODEL' 8080")
    fi
fi
# A non-empty fallback_providers list silently overrides fallback_model.
if ! grep -qE '^fallback_providers:[[:space:]]*\[[[:space:]]*\][[:space:]]*(#.*)?$' "$CONFIG" 2>/dev/null; then
    problems+=("config.yaml fallback_providers is non-empty and takes priority over fallback_model — the gemma fallback may not be what Hermes uses")
fi

# ── decide what to say ─────────────────────────────────────────────────
now="$(date +%s)"
prev_status="ok"; prev_sig=""; last_alert=0
if [[ -f "$STATE" ]]; then
    prev_status="$(grep -m1 '^status=' "$STATE" | cut -d= -f2-)"
    prev_sig="$(grep -m1 '^sig=' "$STATE" | cut -d= -f2-)"
    last_alert="$(grep -m1 '^last_alert=' "$STATE" | cut -d= -f2-)"
fi
prev_status="${prev_status:-ok}"; last_alert="${last_alert:-0}"

msg=""
if ((${#problems[@]} > 0)); then
    status="bad"
    sig="$(printf '%s|' "${problems[@]}" | cksum | cut -d' ' -f1)"
    log "PROBLEM: ${problems[*]}"
    if [[ "$prev_status" != "bad" || "$sig" != "$prev_sig" || $((now - last_alert)) -ge "$REALERT_SECS" ]]; then
        msg="⚠️ Hermes fallback guard: local fallback is NOT healthy"
        for p in "${problems[@]}"; do msg+=$'\n• '"$p"; done
        ((${#actions[@]} > 0)) && for a in "${actions[@]}"; do msg+=$'\n↳ tried: '"$a"; done
        last_alert="$now"
    fi
else
    status="ok"; sig=""
    if ((${#actions[@]} > 0)); then
        log "SELF-HEALED: ${actions[*]}"
        msg="♻️ Hermes fallback guard: local fallback self-healed"
        for a in "${actions[@]}"; do msg+=$'\n• '"$a"; done
        last_alert="$now"
    elif [[ "$prev_status" == "bad" ]]; then
        log "RECOVERED"
        msg="✅ Hermes fallback guard: local fallback is healthy again"
        last_alert="$now"
    else
        log "ok"
    fi
fi

{ echo "status=$status"; echo "sig=$sig"; echo "last_alert=$last_alert"; echo "busy_since=$busy_since"; echo "updated=$now"; } > "$STATE"

if [[ -n "$msg" ]]; then
    echo "$msg"
elif ((VERBOSE)); then
    echo "fallback guard: $status$([[ $busy == 1 ]] && echo ' (model busy — probe skipped)') — $EXPECT_MODEL @ $EXPECT_URL"
fi
exit 0
