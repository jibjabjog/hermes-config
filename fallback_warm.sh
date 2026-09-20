#!/bin/bash
# fallback_warm.sh — keep gemma's PROMPT CACHE warm for Hermes' real Telegram prompt.
#
# Why: on this CPU box gemma reads prompts at ~20 tok/s and Hermes' fixed prompt
# (system prompt + 23 tool schemas) is ~20k tokens, so a COLD first failover turn
# costs ~17-20 min. Once that prefix is in llama.cpp's cache, a turn costs seconds.
# This builds the exact system prompt + tools Hermes sends on Telegram (using
# Hermes' own inspection code, offline — nothing is sent to Telegram) and feeds
# it to gemma as a 1-token completion, so the cache is warm BEFORE a failover.
#
# Called by fallback_guard.sh when gemma is healthy and idle. Silent (log only).
#   - already warm  -> the request returns in seconds; logged as "warm".
#   - cold          -> the prefill takes ~17-20 min, so it runs DETACHED; the
#                      guard sees the model as busy meanwhile and never restarts it.
# Re-warms automatically after a router restart (cache lost) or when the live
# session's prompt changes (a session reset, a new memory, a skills change).
#
#   fallback_warm.sh          # normal
#   fallback_warm.sh -v       # also print what it did
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PY="$HERMES_HOME/hermes-agent/venv/bin/python"
LOG="$HERMES_HOME/logs/fallback_guard.log"
EXPECT_MODEL="${FALLBACK_EXPECT_MODEL:-google/gemma-4-E2B-it-qat-q4_0-gguf:IT}"
EXPECT_URL="${FALLBACK_EXPECT_URL:-http://127.0.0.1:8080/v1}"
PLATFORM="${WARM_PLATFORM:-telegram}"
PAYLOAD="${WARM_PAYLOAD:-$HERMES_HOME/cache/warm_${PLATFORM}.json}"
WAIT="${WARM_QUICK_WAIT:-25}"          # how long to wait for the "already warm" fast path
MAX_SECS="${WARM_MAX_SECS:-3000}"      # ceiling for a cold prefill
VERBOSE=0; [[ "${1:-}" == "-v" ]] && VERBOSE=1

mkdir -p "$(dirname "$PAYLOAD")" "$(dirname "$LOG")"
log() { echo "[$(date '+%F %T')] warm: $*" >> "$LOG"; say "$*"; }
say() { (( VERBOSE )) && echo "warm: $*"; return 0; }

# ── 1. the payload: what Hermes will really send on this platform ─────────
# Hermes caches each session's system prompt (byte-identical, so provider prefix
# caches survive) and on failover rewrites ONLY the last "Model:"/"Provider:" lines
# (chat_completion_helpers.rewrite_prompt_model_identity). So the exact prompt a
# failover sends is: the live session's stored prompt, with those two lines set to
# the fallback. That is read (read-only) from state.db. If there is no session yet,
# fall back to an offline render of the prompt. Tool schemas come from Hermes'
# own offline agent for the platform's toolsets. Rebuilt every run and swapped in
# only if it changed — a changed prompt then re-warms just its changed tail.
if ! ( cd "$HOME" && timeout 180 "$PY" - "$PLATFORM" "$PAYLOAD.tmp" <<'PYEOF'
import json, os, re, sqlite3, sys
sys.path.insert(0, os.path.expanduser("~/.hermes/hermes-agent"))
import agent.agent_init as ai
ai._enforce_minimum_context = lambda agent: None   # offline render, not a live session
plat, out = sys.argv[1:3]
from hermes_cli.config import load_config
fb = load_config().get("fallback_model") or {}
model, provider = fb.get("model"), fb.get("provider")
from hermes_cli.prompt_size import _build_inspection_agent
from agent.system_prompt import build_system_prompt
a = _build_inspection_agent(plat)
sp, src = None, "offline"
try:
    db = sqlite3.connect("file:" + os.path.expanduser("~/.hermes/state.db") + "?mode=ro", uri=True, timeout=5)
    row = db.execute(
        "select p.prompt from sessions s join system_prompts p on p.hash = s.system_prompt_hash "
        "where s.source = ? order by coalesce(s.last_activity_at, s.started_at) desc limit 1", (plat,)).fetchone()
    if row and row[0]:
        sp, src = row[0], "live-session"
except Exception:
    pass
if sp is None:
    sp = build_system_prompt(a)
for label, value in (("Model", model), ("Provider", provider)):   # last occurrence only, as Hermes does
    if value:
        m = list(re.finditer(rf"(?m)^{label}: .*$", sp))
        if m:
            sp = f"{sp[:m[-1].start()]}{label}: {value}{sp[m[-1].end():]}"
body = {"model": model, "messages": [{"role": "system", "content": sp}, {"role": "user", "content": "ping"}],
        "tools": a.tools, "max_tokens": 1, "cache_prompt": True}
json.dump(body, open(out, "w"))
print(src, len(sp), len(a.tools), file=sys.stderr)
PYEOF
) 2>"$PAYLOAD.info"; then
    log "could not build the $PLATFORM payload: $(tail -n 2 "$PAYLOAD.info" | tr '\n' ' ' | cut -c1-300) — skipping"
    rm -f "$PAYLOAD.tmp" "$PAYLOAD.info"; exit 0
fi
info="$(grep -E '^(live-session|offline) [0-9]+ [0-9]+$' "$PAYLOAD.info" | tail -1)"; rm -f "$PAYLOAD.info"
if [[ -s "$PAYLOAD.tmp" ]] && ! cmp -s "$PAYLOAD.tmp" "$PAYLOAD"; then
    mv "$PAYLOAD.tmp" "$PAYLOAD"
    log "$PLATFORM payload ${PAYLOAD##*/} updated ($(wc -c < "$PAYLOAD") bytes; source/sys-chars/tools: ${info:-?})"
else
    rm -f "$PAYLOAD.tmp"
fi
[[ -s "$PAYLOAD" ]] || { log "no $PLATFORM payload — skipping"; exit 0; }

# One prefill at a time: identical requests do NOT share work, they queue on other
# slots and split the CPU (a manual re-run while one was outstanding stacked three).
INFLIGHT="$PAYLOAD.inflight"
if [[ -f "$INFLIGHT" ]] && kill -0 "$(cat "$INFLIGHT" 2>/dev/null)" 2>/dev/null; then
    log "$PLATFORM warm-up already in flight (pid $(cat "$INFLIGHT")) — not sending another"
    exit 0
fi

# ── 2. send it. Fast return = already warm; slow = cold prefill, run detached ─
RESP="$(mktemp "${TMPDIR:-/tmp}/warm.XXXXXX")"
t0=$(date +%s)
# 9>&- : never inherit the guard's lock (a cold prefill outlives many guard runs).
# setsid/nohup + closed stdio : cron must not wait on this process.
setsid nohup bash -c '
    resp=$(curl -s -m "$1" "$2/chat/completions" -H "Content-Type: application/json" --data-binary @"$3")
    printf "%s" "$resp" > "$4"
    echo done > "$4.done"
' _ "$MAX_SECS" "$EXPECT_URL" "$PAYLOAD" "$RESP" </dev/null >/dev/null 2>&1 9>&- &
bgpid=$!
echo "$bgpid" > "$INFLIGHT"

for ((i = 0; i < WAIT; i++)); do
    [[ -e "$RESP.done" ]] && break
    sleep 1
done

report() {   # $1 = response file, $2 = how long it took
    local ptok cached
    ptok="$(jq -r '.usage.prompt_tokens // empty' "$1" 2>/dev/null)"
    cached="$(jq -r '.timings.cache_n // empty' "$1" 2>/dev/null)"
    if [[ -n "$ptok" ]]; then
        log "$PLATFORM prompt ready: ${cached:-?}/${ptok} tokens served from cache, ${2}s"
    else
        log "$PLATFORM warm-up request failed after ${2}s: $(head -c 200 "$1" 2>/dev/null)"
    fi
}

if [[ -e "$RESP.done" ]]; then
    report "$RESP" "$(( $(date +%s) - t0 ))"
    rm -f "$RESP" "$RESP.done" "$INFLIGHT"
else
    log "$PLATFORM prompt is COLD — prefilling in the background (~17-20 min at ~20 tok/s; pid $bgpid)"
    # Clean up + report when it finishes, without holding cron or the lock.
    setsid nohup bash -c '
        while [[ ! -e "$1.done" ]]; do sleep 5; done
        ptok=$(jq -r ".usage.prompt_tokens // empty" "$1" 2>/dev/null)
        cached=$(jq -r ".timings.cache_n // empty" "$1" 2>/dev/null)
        if [[ -n "$ptok" ]]; then
            echo "[$(date "+%F %T")] warm: $2 prefill finished — prompt is now warm (${cached:-0}/${ptok} tokens were cached)" >> "$3"
        else
            echo "[$(date "+%F %T")] warm: $2 background warm-up FAILED: $(head -c 200 "$1")" >> "$3"
        fi
        rm -f "$1" "$1.done" "$4"
    ' _ "$RESP" "$PLATFORM" "$LOG" "$INFLIGHT" </dev/null >/dev/null 2>&1 9>&- &
fi
exit 0
