Operating System: Ubuntu 24.04 ARM64 (Oracle Cloud Free Tier). Hardware: 4-core Ampere A1, 24 GB RAM, no GPU.
§
User: huey. Software stack: Node.js 22, Python 3.12. Services: llama-server running on 127.0.0.1:8080. Models directory: ~/models.
§
User prefers concise answers with exact commands. When verifying llama.cpp setup, document both the working configuration and session-specific verification details in skill references.
§
When verifying working llama.cpp configurations in sessions, add both general setup verification and session-specific details to the llama-cpp skill's references directory.
§
User huey: Ubuntu 24.04 ARM64, 4-core Ampere A1, 24GB RAM, no GPU. Prefers concise answers with exact commands. Running llama-server on 127.0.0.1:8080, models in ~/models. Values efficiency and pragmatic technical solutions.
§
Durable technique captured in llama-cpp references/hermes-cpu-optimization.md (session 2026-08-22): CPU-only Hermes optimization — freerouter + openrouter/free primary, qwen35-fast local fallback, qwen35-tiny emergency preset, config tuning (max_turns 30, timeout 3000, image disabled, memory 3500/flush 10), health-check ping cron, verification commands. Protected skill llama-cpp; reference file added to its references/ directory.
§
Telegram UX plugins (evey-telegram-ux: telegram_card, telegram_status) are formatting-only tools — they return HTML/plain that must be paired with a delivery mechanism (send_message or gateway pipeline) to reach the user. They don't auto-deliver as standalone tool calls.
§
Whisper base model installed in ~/.hermes/hermes-agent/venv (session 2026-08-25); transcription confirmed working on cached .ogg files. evey_telegram-ux plugin loaded in gateway — provides telegram_card and telegram_status tools for rich HTML formatting (icons: [i]/[+]/[!]/[x]). evey-status plugin loaded — status_check aggregates dashboard data (fails if dashboard port 9119 not running).
§
llama-server quirk: --quiet is an invalid flag (use -lv 2 instead). Verified session 2026-08-26 spinning Qwen3.5-0.8B on port 45072. Primary 8080 still healthy.
§
Session 2026-08-26: Built freerouter_failover.sh — automatic OpenRouter → local qwen35-tiny (Qwen3.5-0.8B on port 45072) failover with Telegram alerts. Loads bot token and chat ID from config file. Gateway-restart guarded (skipped when running inside gateway process to prevent SIGTERM self-kill). Now called by Freerouter cron (06:00 daily, deliver: local, no_agent). Backup qwen35-tiny runs 4 threads, ctx=10240, CPU-only, OpenBLAS. Alias is **Inky** (updated 2026-08-27). Earlier "Inky" reference = old nickname for qwen35-tiny preset.
§
GitHub backup repo: jibjabjog/hermes-backup (private) for .hermes/ config, failover scripts, presets. gh CLI authenticated with scopes: gist, read:org, repo, workflow.
§
Backup cron: hermes-backup daily 03:00 UTC, runs backup_hermes.sh (no_agent). Syncs freerouter_failover.sh, llama-presets.ini, config.yaml to GitHub.
§
Failover: freerouter_failover.sh wraps freerouter.py with automatic qwen35-tiny (port 45072) fallback. Telegram notifications via send_telegram_update(). Gateway restart guarded to avoid self-kill.
§
User expects local backup model to be named **Inky** (0.8B Q4_K_M on port 45072) — alias updated to Inky 2026-08-27, ctx-size bumped 2048→10240.
§
For any Gmail, Calendar, Drive, Docs, Sheets, or Contacts task: always load and use the google-workspace skill. OAuth is already configured. Never use himalaya.