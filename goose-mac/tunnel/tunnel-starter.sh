#!/bin/bash
# tunnel-starter.sh — Manage the Cloudflare Tunnel using OAuth2 (browser login)
#
# NO TOKEN SHARING: this script uses `cloudflared tunnel login` (OAuth2 browser
# flow) which saves a cert.pem to ~/.cloudflared/. The tunnel is then run with
# the named-tunnel + cert, so no CLOUDFLARE_TUNNEL_TOKEN is ever needed locally.
#
# Modes:
#   login        → OAuth2 browser login (one-time, refresh expired cert)
#   create       → create the named tunnel (once)
#   route        → route DNS hostname to tunnel (once)
#   foreground   → run now, Ctrl+C to stop (best for trying in a chat)
#   background   → run with nohup, survives closing the terminal/chat
#   install      → install as a launchd service (survives reboots)
#   stop         → kill a running background tunnel
#   logs         → tail the last 50 lines of tunnel output
#   status       → check if tunnel is alive
#
# Alternative (Docker / remote server): set TUNNEL_MODE=token and
# export CLOUDFLARE_TUNNEL_TOKEN=<from dashboard> to use --token mode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="/tmp/cloudflared-goose-bot.pid"
LOG_FILE="/tmp/cloudflared-goose-bot.log"
TUNNEL_NAME="${TUNNEL_NAME:-goose-bot-tunnel}"
TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-bot-api.yourdomain.com}"
TUNNEL_MODE="${TUNNEL_MODE:-cert}"   # cert (OAuth2) | token
LAUNCHD_LABEL="com.cloudflare.goosebot.tunnel"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Prerequisites ───
validate_prereqs() {
    if ! command -v cloudflared &>/dev/null; then
        echo -e "${RED}❌ cloudflared not found${NC}"
        echo "   Install: brew install cloudflared"
        exit 1
    fi
}

# ─── OAuth2 helpers ───
cert_valid() {
    [ -f "$HOME/.cloudflared/cert.pem" ] || return 1
    cloudflared tunnel list >/dev/null 2>&1
}

ensure_login() {
    validate_prereqs
    if cert_valid; then
        echo -e "${GREEN}✓ OAuth2 certificate valid (${HOME}/.cloudflared/cert.pem)${NC}"
        return 0
    fi
    echo -e "${YELLOW}⏳ Running OAuth2 browser login...${NC}"
    echo -e "${BLUE}   A browser window will open. Sign in to your Cloudflare account.${NC}"
    cloudflared tunnel login
    if ! cert_valid; then
        echo -e "${RED}❌ Login failed — check the browser flow.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ OAuth2 login complete (cert.pem saved)${NC}"
}

ensure_tunnel() {
    if cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
        echo -e "${GREEN}✓ Tunnel '$TUNNEL_NAME' exists${NC}"
        return 0
    fi
    echo -e "${YELLOW}⏳ Creating tunnel '$TUNNEL_NAME'...${NC}"
    cloudflared tunnel create "$TUNNEL_NAME"
    echo -e "${GREEN}✓ Tunnel created${NC}"
}

ensure_route() {
    if cloudflared tunnel info "$TUNNEL_NAME" 2>/dev/null | grep -q "$TUNNEL_DOMAIN"; then
        echo -e "${GREEN}✓ DNS route $TUNNEL_DOMAIN → $TUNNEL_NAME exists${NC}"
        return 0
    fi
    echo -e "${YELLOW}⏳ Routing $TUNNEL_DOMAIN → $TUNNEL_NAME...${NC}"
    cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_DOMAIN"
    echo -e "${GREEN}✓ DNS route created${NC}"
}

# ─── Run command construction ───
run_args() {
    if [ "$TUNNEL_MODE" = "token" ]; then
        if [ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
            echo -e "${RED}❌ TUNNEL_MODE=token requires CLOUDFLARE_TUNNEL_TOKEN env var${NC}"
            exit 1
        fi
        echo "cloudflared tunnel run --token $CLOUDFLARE_TUNNEL_TOKEN --no-autoupdate --metrics 0.0.0.0:20241 $TUNNEL_NAME"
    else
        echo "cloudflared tunnel run --no-autoupdate --metrics 0.0.0.0:20241 $TUNNEL_NAME"
    fi
}

# ─── Commands ───

cmd_login() {
    ensure_login
    ensure_tunnel
    ensure_route
    echo -e "${GREEN}✅ Tunnel ready: https://$TUNNEL_DOMAIN${NC}"
}

cmd_foreground() {
    cmd_login
    local args
    args=$(run_args)
    echo -e "${GREEN}🚀 Starting Cloudflare Tunnel (foreground, ${TUNNEL_MODE} mode)${NC}"
    echo -e "${YELLOW}   Press Ctrl+C to stop${NC}"
    echo ""
    # shellcheck disable=SC2086
    exec $args
}

cmd_background() {
    cmd_login
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "${YELLOW}⚠️  Tunnel already running (PID $(cat $PID_FILE))${NC}"
        echo "   Use: ./tunnel-starter.sh stop"
        exit 1
    fi

    local args
    args=$(run_args)
    echo -e "${GREEN}🚀 Starting Cloudflare Tunnel (background, ${TUNNEL_MODE} mode)${NC}"
    echo -e "${BLUE}   PID file: $PID_FILE${NC}"
    echo -e "${BLUE}   Log file: $LOG_FILE${NC}"

    # shellcheck disable=SC2086
    nohup $args > "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 2

    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${GREEN}✅ Tunnel running (PID $pid)${NC}"
        echo -e "   Logs: tail -f $LOG_FILE"
        echo -e "   Stop:  ./tunnel-starter.sh stop"
    else
        echo -e "${RED}❌ Tunnel failed to start — check logs:${NC}"
        tail -n 20 "$LOG_FILE"
        rm -f "$PID_FILE"
        exit 1
    fi
}

cmd_install() {
    cmd_login
    local args
    args=$(run_args)

    if [ -f "$LAUNCHD_PLIST" ]; then
        echo -e "${YELLOW}⚠️  launchd service already installed at $LAUNCHD_PLIST${NC}"
        read -rp "   Overwrite? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    fi

    cat > "$LAUNCHD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHD_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>$args 2>&amp;1 | /usr/bin/logger -t cloudflared-goose</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardErrorPath</key>
    <string>/tmp/cloudflared-goose-bot.err</string>
    <key>StandardOutPath</key>
    <string>/tmp/cloudflared-goose-bot.out</string>
</dict>
</plist>
PLIST

    echo -e "${GREEN}✅ LaunchAgent created at $LAUNCHD_PLIST${NC}"
    launchctl load "$LAUNCHD_PLIST" 2>/dev/null || launchctl bootstrap gui/$(id -u) "$LAUNCHD_PLIST"
    echo -e "   Started. It will auto-start on reboot."
    echo -e "   Stop:   launchctl unload $LAUNCHD_PLIST"
    echo -e "   Logs:   log stream --predicate 'process == \"cloudflared-goose\"'"
}

cmd_stop() {
    local found=0
    if launchctl list "$LAUNCHD_LABEL" &>/dev/null; then
        echo -e "${YELLOW}🛑 Stopping launchd service...${NC}"
        launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
        found=1
    fi

    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${YELLOW}🛑 Stopping background tunnel (PID $pid)...${NC}"
            kill "$pid" 2>/dev/null || true
            sleep 1
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
            fi
            found=1
        fi
        rm -f "$PID_FILE"
    fi

    local pids
    pids=$(pgrep -a cloudflared | grep "$TUNNEL_NAME" | awk '{print $1}' || true)
    if [ -n "$pids" ]; then
        echo -e "${YELLOW}🛑 Stopping stray cloudflared processes...${NC}"
        echo "$pids" | xargs kill 2>/dev/null || true
        found=1
    fi

    if [ "$found" -eq 0 ]; then
        echo -e "${YELLOW}ℹ️  No tunnel process found${NC}"
    else
        echo -e "${GREEN}✅ Tunnel stopped${NC}"
    fi
}

cmd_logs() {
    if [ -f "$LOG_FILE" ]; then
        echo -e "${BLUE}📄 Last 50 lines of $LOG_FILE${NC}\n"
        tail -n 50 "$LOG_FILE"
    else
        echo -e "${YELLOW}⚠️  No log file found at $LOG_FILE${NC}"
        echo "   The tunnel may be running via launchd or hasn't logged yet."
    fi
}

cmd_status() {
    local running=0

    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${GREEN}✅ Background tunnel running (PID $pid)${NC}"
            echo -e "   Log: $LOG_FILE"
            running=1
        else
            echo -e "${RED}⚠️  PID file exists but process is dead${NC}"
            rm -f "$PID_FILE"
        fi
    fi

    if launchctl list "$LAUNCHD_LABEL" &>/dev/null; then
        echo -e "${GREEN}✅ launchd service installed and running${NC}"
        echo -e "   Plist: $LAUNCHD_PLIST"
        running=1
    fi

    local pids
    pids=$(pgrep -a cloudflared | grep "$TUNNEL_NAME" | awk '{print $1}' || true)
    if [ -n "$pids" ]; then
        echo -e "${GREEN}✅ Found running cloudflared tunnel(s):${NC}"
        pgrep -a cloudflared | grep "$TUNNEL_NAME"
        running=1
    fi

    if [ "$running" -eq 0 ]; then
        echo -e "${RED}❌ No tunnel is currently running${NC}"
        echo "   Start with: ./tunnel-starter.sh foreground"
    fi
}

# ─── Main ───
CMD="${1:-foreground}"

case "$CMD" in
    login)        cmd_login ;;
    create)       ensure_login && ensure_tunnel && ensure_route ;;
    route)        ensure_login && ensure_route ;;
    foreground)   cmd_foreground ;;
    background)   cmd_background ;;
    install)      cmd_install ;;
    stop)         cmd_stop ;;
    logs)         cmd_logs ;;
    status)       cmd_status ;;
    *)
        echo -e "${RED}Usage: $0 {login|create|route|foreground|background|install|stop|logs|status}${NC}"
        exit 1
        ;;
esac