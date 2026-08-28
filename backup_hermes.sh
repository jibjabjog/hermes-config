#!/bin/bash
# backup_hermes.sh — syncs Hermes config to GitHub hermes-config
# Runs via cron (daily at 03:00 UTC)
set -euo pipefail

BACKUP_DIR="/home/huey/.hermes-config-backup"
LOG_FILE="/home/huey/.hermes/logs/backup.log"
GIT_REMOTE="https://github.com/jibjabjog/hermes-config.git"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Setup: clone or update the backup repo
setup_repo() {
    if [[ -d "$BACKUP_DIR/.git" ]]; then
        cd "$BACKUP_DIR"
        git pull --quiet origin master 2>/dev/null || true
    else
        mkdir -p "$BACKUP_DIR"
        cd "$BACKUP_DIR"
        git init
        git remote add origin "$GIT_REMOTE"
        git pull origin master 2>/dev/null || true
    fi
}

# Sync latest files from live configs
sync_configs() {
    log "Syncing live configs..."
    cp /home/huey/.hermes/scripts/freerouter_failover.sh "$BACKUP_DIR/" 2>/dev/null || true
    cp /home/huey/.hermes/scripts/backup_hermes.sh "$BACKUP_DIR/" 2>/dev/null || true
    cp /home/huey/llama-presets.ini "$BACKUP_DIR/" 2>/dev/null || true
    cp /home/huey/.hermes/config.yaml "$BACKUP_DIR/" 2>/dev/null || true
    # Backup critical identity files
    cp /home/huey/.hermes/SOUL.md "$BACKUP_DIR/" 2>/dev/null || true
    cp /home/huey/.hermes/memories/MEMORY.md "$BACKUP_DIR/" 2>/dev/null || true
    cp /home/huey/.hermes/memories/USER.md "$BACKUP_DIR/" 2>/dev/null || true

    # Redact any literal secret-shaped values from the backup-dir COPY of
    # config.yaml before it's ever staged/committed — never touches the live
    # ~/.hermes/config.yaml. See AUDIT.md B.3.
    if [[ -f "$BACKUP_DIR/config.yaml" ]]; then
        REDACT_OUT=$(python3 /home/huey/.hermes/scripts/redact_config_secrets.py "$BACKUP_DIR/config.yaml" 2>&1) || {
            log "ERROR: redact_config_secrets.py failed: $REDACT_OUT"
            return 1
        }
        log "$REDACT_OUT"
    fi

    log "Configs synced"
}

# Commit and push if changes
commit_and_push() {
    cd "$BACKUP_DIR"
    git config user.name "jibjabjog" 2>/dev/null || true
    git config user.email "jibjabjog@users.noreply.github.com" 2>/dev/null || true

    if git diff --quiet && git diff --cached --quiet; then
        log "No changes — skipping push"
        return 0
    fi

    git add -A
    git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')"
    git push origin master || {
        log "ERROR: Push failed"
        return 1
    }
    log "Backup pushed to hermes-config"
}

# MAIN
log "========================================="
log "Hermes Backup — START"
log "========================================="

setup_repo
sync_configs
commit_and_push

log "Backup complete"
exit 0
