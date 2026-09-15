# Hermes Configuration Backup & Failover Setup

**Version:** 1.0
**Last Updated:** 2026-08-26
**Author:** huey

## Overview

This repository contains the backup and failover configuration for the **Hermes Agent** system on Ubuntu 24.04 ARM64. It includes:

- **Failover Script** (`freerouter_failover.sh`) — Automatic fallback from OpenRouter to local `qwen35-tiny` backup when freerouter fails
- **Backup Script** (`backup_hermes.sh`) — Daily sync of live configs to GitHub
- **Model Presets** (`llama-presets.ini`) — Local model configurations for llama.cpp
- **Hermes Config** (`config.yaml`) — Complete Hermes Agent configuration

## System Architecture

### Primary Setup
```
Local Hermes Instance (127.0.0.1:8080)
├── OpenRouter/free (primary)
├── Local qwen35-tiny backup (127.0.0.1:45072)
└── Failover Script → Switches to backup on freerouter failure
```

### Failover Logic
1. **freerouter.py** runs daily at 06:00 UTC to fetch OpenRouter models
2. **freerouter_failover.sh** wraps freerouter with health checks:
   - Verifies `qwen35-tiny` (port 45072) is running
   - On freerouter failure → activates local backup, sends Telegram alert
   - On success → restores OpenRouter, sends confirmation
3. **Automatic Recovery** — Script attempts to switch back on next successful freerouter run

### Backup System
- **Cron:** Daily at 03:00 UTC (`hermes-backup`)
- **Target:** `jibjabjog/hermes-config` GitHub repo
- **Content:** Live config copies, failover script, model presets
- **Logging:** `/home/huey/.hermes/logs/backup.log`

## Components

### 1. Failover Script (`freerouter_failover.sh`)

**Purpose:** Automatic failover when OpenRouter services fail

**Key Features:**
- Health checks on `qwen35-tiny` (port 45072)
- Local backup startup if not running
- Telegram notifications for both success and failover events
- Gateway restart handling (detects if running inside gateway)

**Usage:**
```bash
# Live run (normal operation)
./freerouter_failover.sh live

# Dry-run for testing
./freerouter_failover.sh dry
```

### 2. Backup Script (`backup_hermes.sh`)

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

### 3. Model Presets (`llama-presets.ini`)

**Configuration sections:**
- `qwen35-tiny` — the sole local fallback model (0.8B Q4_K_M, ctx-size 2048)
- `tiny-test` — additional backup preset
- `qwen35-fast` (4B) — **retired 2026-09-15.** Originally intended as a
  second, "everyday" fallback tier ahead of qwen35-tiny, running behind a
  multi-model router (`llama-router.service`, port 8080). That router setup
  drifted out of sync with `config.yaml` — `fallback_model` and 10 of 11
  `auxiliary.*` sub-configs ended up silently pointing at a dead port or the
  real OpenRouter cloud with a placeholder key, so the "everyday" tier
  hadn't actually been reachable for weeks. Running a 4B model with any
  real intent is also CPU-bound-hostile (~5.7GB RSS just sitting there).
  Simplified to a single local tier: `qwen35-tiny` is now every fallback
  path's only target, and the router service + 4B model file are gone. This
  section is left in `llama-presets.ini` as inert history, not actively used.

**Usage:** Loaded by llama-server via `--models-preset` flag

### 4. Hermes Config (`config.yaml`)

**Key Sections:**
- `model.default: openrouter/free` — Primary model selection
- `auxiliary.vision.model` — Vision model (rotates via Freerouter; stays on
  OpenRouter, not local)
- `fallback_model` and all `auxiliary.*` sub-configs except `vision` — point
  at `qwen35-tiny` (`http://127.0.0.1:45072/v1`), the one local model on
  this box
- Various personality settings (concise, technical, creative, etc.)
- Toolsets and gateway configuration
- One exception left as-is: `custom_providers` has an entry named "Bert"
  with a stray `model: qwen35-fast` default left over from the same
  misconfiguration, but its `base_url` correctly points at real OpenRouter
  behind a genuine ~30-model catalog. It's inert (nothing selects it as the
  active provider), so it wasn't force-fit into the qwen35-tiny fix —
  flagged for whoever eventually cleans it up.

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
cp .hermes-config/*.ini ~/models/
cp .hermes-config/config.yaml ~/.hermes/

# Make scripts executable
chmod +x ~/.hermes/scripts/freerouter_failover.sh
chmod +x ~/.hermes/scripts/backup_hermes.sh

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

### Start Services

Just the one local model now — no router, no second tier:

```bash
~/llama.cpp/build/bin/llama-server \
  --host 127.0.0.1 --port 45072 \
  --alias Inky \
  --model ~/models/Qwen3.5-0.8B-Q4_K_M.gguf \
  --ctx-size 10240 --threads 4 \
  --n-gpu-layers 0 \
  --cache-type-k q4_0 --cache-type-v q4_0 \
  > ~/logs/qwen35-tiny.log 2>&1 &
```

In practice this runs as `llama-qwen35-tiny.service` (systemd `--user` unit,
`Restart=always`), not a bare backgrounded command — see the
`jibjabjog/huey-origins` setup guide for the full unit file. (The
`--models-preset`/router invocation that used to start a second tier here
was removed along with `llama-router.service` — see the Model Presets
section above.)

## Operation

### Daily Routine
1. **03:00** — Backup script runs, syncs configs to GitHub
2. **06:00** — freerouter runs via cron, potentially failing over to qwen35-tiny
3. **Throughout** — Services run with automatic health monitoring

### Monitoring
```bash
# Check backup status
cat ~/.hermes/logs/backup.log

# Check qwen35-tiny health
curl http://127.0.0.1:45072/health

# Check primary service health
curl http://127.0.0.1:8080/health
```

### Telegram Notifications
When configured, you'll receive alerts for:
- ✅ Successful freerouter runs (OpenRouter models refreshed)
- ⚠️ Freerouter failures (OpenRouter model refresh unavailable — `fallback_model`
  is already permanently pinned to `qwen35-tiny`, so there's no separate
  "switch" event to report anymore, just the state)
- 🔄 Recovery confirmations

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

#### Failover Not Triggering
```bash
cat ~/.hermes/logs/freerouter_failover.log
```
**Verify:** freerverouter exit codes, health check endpoints

### Manual Recovery
```bash
# Force failover
./freerouter_failover.sh dry

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