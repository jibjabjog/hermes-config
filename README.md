# Hermes Configuration Backup & Failover Setup

**Version:** 3.0
**Last Updated:** 2026-09-22
**Author:** huey

## Overview

This repository contains the backup and failover configuration for the **Hermes Agent** system on Ubuntu 24.04 ARM64. It includes:

- **Failover Guard** (`fallback_guard.sh` + `fallback_warm.sh`) — keeps the
  real `fallback_model` (gemma-4-E2B, behind a router) actually working, not
  just running: service-up check, a real-completion probe, config drift
  detection, and prompt-cache warming
- **Freerouter Script** (`freerouter_failover.sh`) — daily OpenRouter
  model-catalog refresh + a health check on Inky (unrelated to
  `fallback_model` — see Failover Logic below, this trips people up)
- **Backup Script** (`backup_hermes.sh`) — daily sync of live configs to GitHub
- **Model Presets** (`llama-presets.ini`) — local model configurations for llama.cpp
- **Hermes Config** (`config.yaml`) — complete Hermes Agent configuration

## System Architecture

Two local models, two different jobs — this has changed twice (see
`Model Presets` below for why) and is easy to get wrong by reasoning from an
older snapshot of this repo:

```
Local Hermes Instance
├── OpenRouter/free (primary)
├── gemma-4-E2B, behind llama-router.service (127.0.0.1:8080)
│   └── Hermes' real fallback_model — used when the primary model errors
│   └── kept healthy + warm by fallback_guard.sh (every 5 min)
└── qwen35-tiny "Inky" (127.0.0.1:45072)
    ├── all 11 auxiliary.* tasks (compression, title_generation, etc.)
    └── the local-llama-ping health beacon
```

### Failover Logic — two separate mechanisms, don't conflate them

**`fallback_guard.sh`** (every 5 min) is what actually owns the real
fallback path: checks `llama-router.service` is up (starts it if not),
proves gemma answers a real completion — not just that the port is open —
restarts the router once if it doesn't, checks `config.yaml`'s
`fallback_model` still points at gemma (drift check), and keeps its
~19,000-token prompt cache warm so a real failover doesn't pay a 17-20
minute cold-start penalty. Silent on Telegram when healthy; speaks up only
on a state change.

**`freerouter_failover.sh`** (daily, 06:00) is unrelated to the above as of
2026-09-15 — it checks OpenRouter's model catalog and Inky specifically,
and no longer touches `fallback_model` at all (an earlier version used it
to flip `fallback_model` between two local tiers on every run; that
machinery is gone, see Model Presets).

### Backup System
- **Cron:** Daily at 03:00 UTC (`hermes-backup`)
- **Target:** `jibjabjog/hermes-config` GitHub repo
- **Content:** live config copies, both failover scripts, model presets
- **Logging:** `/home/huey/.hermes/logs/backup.log`

## Components

### 1. Failover Guard (`fallback_guard.sh` + `fallback_warm.sh`)

**Purpose:** proves the real `fallback_model` (gemma) actually works, on a
5-minute cron — this exists specifically because the two incidents below
both happened underneath services that looked healthy.

**`fallback_guard.sh`, every run:**
- starts `llama-router.service` if it isn't running
- sends gemma a real completion request (loads it if needed; restarts the
  router once, then gives up and alerts, if it still doesn't answer)
- checks `config.yaml`'s `fallback_model` still points at gemma at the
  expected URL — pure drift detection, no config edits unless
  `FALLBACK_AUTOFIX_DRIFT=1`
- while healthy and idle, hands off to `fallback_warm.sh`
- silent on Telegram when everything's fine; only posts on a state change
  (problem / self-healed / recovered), plus a 6-hour re-alert while a
  problem persists

**`fallback_warm.sh`:** rebuilds the exact system prompt + tool schemas
Hermes would really send on a Telegram failover (read from the live
session's stored prompt, offline — nothing touches Telegram) and sends it
to gemma as a 1-token completion, so the real failover path never pays a
cold prefill. Runs detached (a cold prefill takes ~17-20 min) so the cron
job itself stays fast.

**Two real incidents this exists because of:**
1. **2026-09-15** — an earlier design (a 4B "everyday" fallback tier ahead
   of Inky) drifted silently: `fallback_model` pointed at a dead port, 10
   of 11 `auxiliary.*` blocks had a placeholder key against the real
   OpenRouter cloud. Nothing was checking, so nobody noticed for weeks.
2. **2026-09-18→22** — after gemma replaced that design, the router
   defaulted to 4 parallel slots with nothing pinning warm-up requests to a
   consistent one. The cache never actually persisted between cycles
   (`0/19058 tokens cached`, every single cycle) — so it silently redid the
   full ~19k-token prefill from scratch every ~20 minutes, non-stop, for
   three days (~300% CPU sustained). Fixed by pinning `parallel = 1` in
   `llama-presets.ini`; confirmed live afterward — a repeat request now
   shows `19057/19058` tokens served from cache in ~1s.

**Usage:**
```bash
fallback_guard.sh          # normal (cron): silent when healthy
fallback_guard.sh -v       # verbose: always print the status line
```

### 2. Freerouter Script (`freerouter_failover.sh`)

**Purpose:** daily OpenRouter model-catalog refresh, plus a health check on
Inky specifically. **Does not touch `fallback_model`** as of 2026-09-15 —
see Failover Logic above if you're expecting this to be the fallback
mechanism, it isn't anymore.

**Key Features:**
- Health checks on `qwen35-tiny`/Inky (port 45072)
- Local backup startup if not running
- Telegram notifications for both success and failure events
- Gateway restart handling (detects if running inside gateway)

**Usage:**
```bash
# Live run (normal operation)
./freerouter_failover.sh live

# Dry-run for testing
./freerouter_failover.sh dry
```

### 3. Backup Script (`backup_hermes.sh`)

**Purpose:** Daily sync of live configuration to GitHub

**Features:**
- Copies live configs to `~/.hermes-backup`
- Commits with timestamp
- Pushes to `jibjabjog/hermes-config` with fallback to origin
- Comprehensive logging

**Crontab Entry:**
```
0 3 * * * /home/huey/.hermes/scripts/backup_hermes.sh
```

### 4. Model Presets (`llama-presets.ini`)

**Configuration sections:**
- `qwen35-tiny` — Inky, handles `auxiliary.*` tasks + the health beacon
  (0.8B Q4_K_M, ctx-size 4096)
- `tiny-test` — additional backup preset
- `[google/gemma-4-E2B-it-qat-q4_0-gguf:IT]` — the real `fallback_model`,
  discovered from the HF cache (`--hf-repo`, no manual download needed).
  `temp = 0.3` and `reasoning = off` are pinned server-side because Hermes
  itself sends neither — left at server defaults, gemma's fix rate on the
  eval project's simulated incident dropped from 3/3 to 1/3 at the
  (unpinned) default temperature of 1.0, and unpinned reasoning cost ~50s
  per reply for no benefit. `load-on-startup = true` keeps it resident so a
  real failover never pays a cold load. **`parallel = 1`** (added
  2026-09-22) — see Failover Logic above; without it the router defaults to
  4 slots and the warm-up cache never actually persists.
- `qwen35-fast` (4B) — **retired 2026-09-15**, superseded by gemma above.
  Was a second "everyday" fallback tier that drifted silently for weeks
  (`fallback_model` pointing at a dead port, 10 of 11 `auxiliary.*` blocks
  hitting the real OpenRouter cloud with a placeholder key) and was a bad
  fit for CPU-only hardware regardless (~5.7GB RSS). Section left in
  `llama-presets.ini` as inert history — the underlying 4B model file is
  deleted, nothing loads it.

**Usage:** Loaded by `llama-router.service` via `--models-preset` flag

### 5. Hermes Config (`config.yaml`)

**Key Sections:**
- `model.default: openrouter/free` — Primary model selection
- `auxiliary.vision.model` — Vision model (rotates via Freerouter; stays on
  OpenRouter, not local)
- `fallback_model` — points at gemma
  (`http://127.0.0.1:8080/v1`, the router)
- every other `auxiliary.*` sub-config (compression, skills_hub, approval,
  mcp, title_generation, triage_specifier, kanban_decomposer,
  profile_describer, curator, web_extract, session_search) — points at
  Inky (`http://127.0.0.1:45072/v1`)
- Various personality settings (concise, technical, creative, etc.)
- Toolsets and gateway configuration
- `custom_providers` has an entry named "Bert" with a real OpenRouter
  `base_url` behind a genuine ~400-model catalog, referenced by
  `key_env: OPENROUTER_API_KEY` (fixed 2026-09-15 — it previously had a
  stray `model: qwen35-fast` default and a placeholder `api_key`, the same
  leftover-templating bug as the auxiliary fix, but needed a different fix
  since this entry's `base_url` is legitimately real OpenRouter, not
  something to repoint locally). It's inert either way — nothing selects
  it as the active provider.

## Setup Instructions

### Prerequisites
```bash
# Ubuntu 24.04 ARM64 (Hermes on CPU-only)
sudo apt update
sudo apt install -y git curl unzip python3 python3-pip

# Clone this repo
cd ~
git clone https://github.com/jibjabjog/hermes-config.git .hermes-config
```

### Environment Setup
```bash
# Copy files to working directory
cp .hermes-config/*.sh ~/.hermes/scripts/
cp .hermes-config/*.ini ~/
cp .hermes-config/config.yaml ~/.hermes/

# Make scripts executable
chmod +x ~/.hermes/scripts/freerouter_failover.sh
chmod +x ~/.hermes/scripts/backup_hermes.sh
chmod +x ~/.hermes/scripts/fallback_guard.sh
chmod +x ~/.hermes/scripts/fallback_warm.sh

# Set up environment variables (add to ~/.bashrc)
export OPENROUTER_API_KEY="your-key-here"
export TELEGRAM_BOT_TOKEN="your-bot-token"
export TELEGRAM_HOME_CHANNEL="your-chat-id"
```

### llama.cpp Setup
```bash
# Clone llama.cpp
cd ~
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build
cmake --build build --config Release

# Create symlinks if needed
ln -sf ~/models/Qwen3.5-0.8B-Q4_K_M.gguf llama.cpp/models/
```

gemma needs no equivalent download step — `--hf-repo` (below) fetches and
caches it automatically on first load.

### Start Services

Two models now, two services — Inky standalone, gemma behind a router:

```bash
# Inky — direct, single model
~/llama.cpp/build/bin/llama-server \
  --host 127.0.0.1 --port 45072 \
  --alias Inky \
  --model ~/models/Qwen3.5-0.8B-Q4_K_M.gguf \
  --ctx-size 10240 --threads 4 \
  --n-gpu-layers 0 \
  --cache-type-k q4_0 --cache-type-v q4_0 \
  > ~/logs/qwen35-tiny.log 2>&1 &

# gemma — via the router, reads llama-presets.ini for its own flags
~/llama.cpp/build/bin/llama-server \
  --host 127.0.0.1 --port 8080 \
  --jinja -fa on -t 4 -ngl 0 -c 65536 \
  --cache-type-k q4_0 --cache-type-v q4_0 \
  --models-preset ~/llama-presets.ini \
  --models-max 2 --models-autoload --timeout 3600 \
  > ~/logs/llama-router.log 2>&1 &
```

In practice these run as `llama-qwen35-tiny.service` and
`llama-router.service` (systemd `--user` units, `Restart=always`), not bare
backgrounded commands — see the `jibjabjog/huey-origins` setup guide for
the full unit files. Once the router is up, register `fallback_guard.sh` as
a 5-minute cron job (`hermes cron create "*/5 * * * *" --name
"fallback-guard" --script fallback_guard.sh --no-agent --deliver
telegram`) — without it, nothing catches the class of drift/cache-eviction
bug described above.

## Operation

### Daily / Recurring Routine
1. **Every 5 min** — `fallback_guard.sh` checks gemma is up, healthy, warm,
   and undrifted; silent unless something changed
2. **03:00** — Backup script runs, syncs configs to GitHub
3. **06:00** — freerouter runs, refreshes the OpenRouter catalog and checks
   Inky (does **not** touch `fallback_model` — see Failover Logic above)
4. **Throughout** — both local models resident; gemma's prompt cache kept
   warm by the guard

### Monitoring
```bash
# Check backup status
cat ~/.hermes/logs/backup.log

# Check the guard's own log — most useful single file for this system
tail -50 ~/.hermes/logs/fallback_guard.log

# Check Inky health (auxiliary tasks + ping)
curl http://127.0.0.1:45072/health

# Check the router + gemma
curl http://127.0.0.1:8080/v1/models

# Confirm gemma's cache is actually being reused, not just that it's up
curl -s http://127.0.0.1:8080/v1/chat/completions -H "Content-Type: application/json" \
  --data-binary @~/.hermes/cache/warm_telegram.json \
  | python3 -c "import json,sys; t=json.load(sys.stdin)['timings']; print(t['cache_n'], '/', t.get('prompt_n'))"
```

### Telegram Notifications
Two independent sources now:
- **`fallback-guard`** (every 5 min, only on state change): ⚠️ local
  fallback not healthy (+ what's wrong, + anything it tried), ♻️ self-healed,
  ✅ healthy again
- **`Freerouter`** (daily): ✅ OpenRouter models refreshed / ⚠️ refresh
  unavailable — this is about Freerouter's own daily catalog rotation, not
  the fallback tier; don't read a Freerouter alert as "the local fallback is
  down," check the guard's own alerts for that

## Configuration

### Google Integration
Google Workspace (Gmail, Calendar, Drive, Contacts, Docs, Sheets) is configured via
OAuth through Hermes's built-in `google-workspace` skill — no separate `gws` CLI or
extra `config.yaml` sections needed. One local-only detail: the skill's `SKILL.md`
is patched to call Hermes's bundled venv Python explicitly
(`~/.hermes/hermes-agent/venv/bin/python`), since the system `python` on this box
lacks the Google client libraries. That patch isn't tracked in this repo and can be
reverted by a `hermes update` — reapply it manually if Google Workspace calls start
failing with import errors after an update.

### GitHub Setup
- Repository: `jibjabjog/hermes-config` (private)
- Required scopes: `repo`, `gist`, `workflow`, `read:org`
- Token: 6-month expiry (user-managed)

## Troubleshooting

### Common Issues

#### Gateway Restart Blocked
```
Error: Command cannot restart the gateway from inside the gateway process
```
**Solution:** Script now detects internal execution and suggests `hermes gateway restart`

#### Backup Not Pushing
```bash
cat ~/.hermes/logs/backup.log
tail -f ~/.hermes/logs/*.log
```
**Check:** GitHub token permissions, remote URL, network connectivity

#### Freerouter Not Triggering (daily catalog refresh — not the fallback path)
```bash
cat ~/.hermes/logs/freerouter_failover.log
```
**Verify:** freerouter exit codes, health check endpoints

#### The real fallback (gemma) seems broken
```bash
tail -100 ~/.hermes/logs/fallback_guard.log
systemctl --user status llama-router.service
grep -A4 '^fallback_model:' ~/.hermes/config.yaml
```
**Check, in order:** is `llama-router.service` actually running; does
`fallback_model` still point at `http://127.0.0.1:8080/v1`
(`google/gemma-4-E2B-it-qat-q4_0-gguf:IT`) — the guard logs a drift warning
if not; does `curl http://127.0.0.1:8080/v1/models` actually list gemma.
**A specific symptom to know:** sustained high CPU on the gemma process with
`0/19058`-style zero-cache-hit lines in `fallback_guard.log` is the
09-18→22 cache-eviction bug — verify `llama-presets.ini`'s gemma section
still has `parallel = 1`; if it's been lost (e.g. a hand-edit, or a future
preset regeneration), that's the fix.

### Manual Recovery
```bash
# Force a Freerouter catalog refresh (dry-run, no side effects)
./freerouter_failover.sh dry

# Force the fallback guard to run now, see its output immediately
./fallback_guard.sh -v

# Check remote status
gh repo view jibjabjog/hermes-config
```

## Future Enhancements

### Advanced Failover
- Multi-model fallback chains
- Performance metrics-based switching
- Geographic routing based on request origin

### Enhanced Backup
- Database backup inclusion
- File integrity verification
- Differential backups for large configs

## License

MIT License. See individual file headers for component-specific licenses.

## Support

For issues and questions:
1. Check the latest logs in `~/.hermes/logs/`
2. Verify GitHub repository status
3. Test scripts manually with dry-run mode
4. Review Telegram notifications

---

*This setup is designed for robust, automated operation with minimal manual intervention. Regular monitoring and periodic manual verification are recommended.*