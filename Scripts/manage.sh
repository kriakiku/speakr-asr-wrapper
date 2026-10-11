#!/usr/bin/env bash
# Build / install / update / run speakr-asr-wrapper as a per-user launchd
# service. Run from anywhere: ./Scripts/manage.sh <command>
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.kriakiku.speakr-asr-wrapper"
PLIST_TEMPLATE="$REPO_DIR/Scripts/$LABEL.plist.template"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
BINARY="$REPO_DIR/.build/release/SpeakrASRWrapper"
DOMAIN="gui/$(id -u)"
PORT="${PORT:-9099}"

log() { echo "==> $*"; }

is_loaded() {
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

cmd_build() {
    log "Building (release)..."
    (cd "$REPO_DIR" && swift build -c release)
    log "Built: $BINARY"
}

# Writes the plist fresh every time (install/update) so a stale
# ProgramArguments path or env var from an older version never lingers.
write_plist() {
    mkdir -p "$HOME/Library/LaunchAgents" "$REPO_DIR/logs"
    sed -e "s#__BINARY_PATH__#$BINARY#g" -e "s#__REPO_DIR__#$REPO_DIR#g" \
        "$PLIST_TEMPLATE" > "$PLIST_DEST"
}

cmd_install() {
    cmd_build
    log "Writing launchd plist -> $PLIST_DEST"
    write_plist
    if is_loaded; then
        log "Already loaded, rebootstrapping..."
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    fi
    launchctl bootstrap "$DOMAIN" "$PLIST_DEST"
    launchctl enable "$DOMAIN/$LABEL"
    log "Installed and started."
    cmd_status
}

# Pull latest, rebuild, and swap the running binary in place. Safe to run
# repeatedly (e.g. from cron/a wakeup) - it's a no-op if nothing changed.
cmd_update() {
    log "Pulling latest from git..."
    (cd "$REPO_DIR" && git pull --ff-only)
    cmd_build
    write_plist
    if is_loaded; then
        log "Restarting service with the new build..."
        launchctl kickstart -k "$DOMAIN/$LABEL"
    else
        log "Service not loaded yet, bootstrapping..."
        launchctl bootstrap "$DOMAIN" "$PLIST_DEST"
        launchctl enable "$DOMAIN/$LABEL"
    fi
    cmd_status
}

cmd_start() {
    if is_loaded; then
        launchctl kickstart -k "$DOMAIN/$LABEL"
    else
        write_plist
        launchctl bootstrap "$DOMAIN" "$PLIST_DEST"
        launchctl enable "$DOMAIN/$LABEL"
    fi
}

cmd_stop() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || log "Already stopped."
}

cmd_restart() {
    if is_loaded; then
        launchctl kickstart -k "$DOMAIN/$LABEL"
    else
        cmd_start
    fi
}

cmd_uninstall() {
    cmd_stop
    rm -f "$PLIST_DEST"
    log "Uninstalled (binary and logs left in place)."
}

cmd_status() {
    if is_loaded; then
        log "launchd: loaded"
        launchctl print "$DOMAIN/$LABEL" 2>&1 | grep -E "state|pid|last exit" || true
    else
        log "launchd: not loaded"
    fi
    # Right after (re)start the process is up but still reloading models,
    # so give it a few seconds before calling the port truly unreachable.
    for _ in 1 2 3 4 5; do
        code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" || echo 000)"
        [ "$code" = "200" ] && break
        sleep 2
    done
    if [ "$code" = "200" ]; then
        log "health: HTTP $code"
    else
        log "health: unreachable on port $PORT (HTTP $code)"
    fi
}

cmd_logs() {
    tail -f "$REPO_DIR/logs/service.log" "$REPO_DIR/logs/service.err.log"
}

case "${1:-}" in
    build) cmd_build ;;
    install) cmd_install ;;
    update) cmd_update ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    *)
        echo "Usage: $0 {build|install|update|start|stop|restart|status|uninstall|logs}"
        echo
        echo "  install   - build + load as a launchd agent (RunAtLoad + KeepAlive)"
        echo "  update    - git pull, rebuild, hot-swap the running service"
        echo "  status    - launchd state + a live health-check against :$PORT"
        exit 1
        ;;
esac
