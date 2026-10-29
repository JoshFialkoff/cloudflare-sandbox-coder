#!/bin/bash
# tunnel-starter.sh — Start, manage, and monitor the Cloudflare Tunnel
# Modes: foreground | background | install | stop | logs | status
#
# Usage:
#   ./tunnel-starter.sh foreground      # Run now, Ctrl+C to stop (best for trying in a chat)
#   ./tunnel-starter.sh background      # Run with nohup, survives closing the terminal/chat
#   ./tunnel-starter.sh install         # Install as a launchd service (survives reboots)
#   ./tunnel-starter.sh stop            # Kill a running background tunnel
#   ./tunnel-starter.sh logs            # Tail the last 50 lines of tunnel output
#   ./tunnel-starter.sh status          # Check if tunnel is alive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOOSE_MAC_DIR="$(dirname "$SCRIPT_DIR")"
TUNNEL_DIR="$SCRIPT_DIR"
PID_FILE="/tmp/cloudflared-goose-bot.pid"
LOG_FILE="/tmp/cloudflared-goose-bot.log"
TUNNEL_NAME="${TUNNEL_NAME:-goose-bot-tunnel}"
LAUNCHD_LABEL="com.cloudflare.goosebot.tunnel"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Helpers ───
validate_prereqs() {
    if ! command -v cloudflared &>/dev/null; then
        echo -e "${RED}❌ cloudflared not found${NC}"
        echo "   Install: brew install cloudflared"
        exit 1
    fi
    if ! command -v bws &>/dev/null; then
        echo -e "${RED}❌ bws (Bitwarden Secrets CLI) not found${NC}"
        echo "   Install: brew install bitwarden/tap/bws"
        exit 1
    fi
    if [ -z "${BWS_PROJECT_ID:-}" ]; then
        echo -e "${YELLOW}⚠️  Set BWS_PROJECT_ID, e.g.:${NC}"
        echo '   export BWS_PROJECT_ID="your-project-uuid"'
        exit 1
    fi
}

load_tunnel_token() {
    local token
    if command -v jq &>/dev/null; then
        token=$(bws secret get CLOUDFLARE_TUNNEL_TOKEN --project-id "$BWS_PROJECT_ID" 2>/dev/null | jq -r '.value // empty' || true)
    else
        # Fallback if jq is missing — parse output manually
        token=$(bws secret get CLOUDFLARE_TUNNEL_TOKEN --project-id "$BWS_PROJECT_ID" 2>/dev/null | grep -o '"value"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\(.*\)".*/\1/' | head -n1 || true)
    fi

    if [ -z "$token" ]; then
        echo -e "${RED}❌ Could not load CLOUDFLARE_TUNNEL_TOKEN from Bitwarden${NC}"
        echo "   Ensure BWS_ACCESS_TOKEN is available and the secret exists in project $BWS_PROJECT_ID"
        exit 1
    fi
    echo "$token"
}

# ─── Commands ───

cmd_foreground() {
    validate_prereqs
    local token
    token=$(load_tunnel_token)

    echo -e "${GREEN}🚀 Starting Cloudflare Tunnel (foreground mode)${NC}"
    echo -e "${BLUE}   Tunnel: $TUNNEL_NAME${NC}"
    echo -e "${YELLOW}   Press Ctrl+C to stop${NC}"
    echo ""

    # Use --no-autoupdate for stability and --metrics so status checks work
    exec cloudflared tunnel run \
        --token "$token" \
        --no-autoupdate \
        --metrics "0.0.0.0:20241" \
        "$TUNNEL_NAME"
}

cmd_background() {
    validate_prereqs
    local token
    token=$(load_tunnel_token)

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "${YELLOW}⚠️  Tunnel already running (PID $(cat $PID_FILE))${NC}"
        echo "   Use: ./tunnel-starter.sh stop"
        exit 1
    fi

    echo -e "${GREEN}🚀 Starting Cloudflare Tunnel (background mode)${NC}"
    echo -e "${BLUE}   Tunnel: $TUNNEL_NAME${NC}"
    echo -e "${BLUE}   PID file: $PID_FILE${NC}"
    echo -e "${BLUE}   Log file: $LOG_FILE${NC}"
    echo ""

    nohup cloudflared tunnel run \
        --token "$token" \
        --no-autoupdate \
        --metrics "0.0.0.0:20241" \
        "$TUNNEL_NAME" \
        > "$LOG_FILE" 2>&1 &

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
    validate_prereqs

    if [ -f "$LAUNCHD_PLIST" ]; then
        echo -e "${YELLOW}⚠️  launchd service already installed at $LAUNCHD_PLIST${NC}"
        read -rp "   Overwrite? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    fi

    local token project_id bws_access_token
    token=$(load_tunnel_token)
    project_id="$BWS_PROJECT_ID"
    bws_access_token="${BWS_ACCESS_TOKEN:-}"

    if [ -z "$bws_access_token" ]; then
        echo -e "${YELLOW}⚠️  BWS_ACCESS_TOKEN is empty. The LaunchAgent will need to load secrets itself.${NC}"
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
        <string>bws run --project $project_id -- cloudflared tunnel run --token '$token' --no-autoupdate '$TUNNEL_NAME' 2>&amp;1 | /usr/bin/logger -t cloudflared-goose</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>BWS_ACCESS_TOKEN</key>
        <string>$bws_access_token</string>
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
    # Stop launchd if installed
    if launchctl list "$LAUNCHD_LABEL" &>/dev/null; then
        echo -e "${YELLOW}🛑 Stopping launchd service...${NC}"
        launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
        found=1
    fi

    # Stop background process if tracked
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

    # Kill any remaining cloudflared matching our tunnel name
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
    foreground)   cmd_foreground ;;
    background)   cmd_background ;;
    install)      cmd_install ;;
    stop)         cmd_stop ;;
    logs)         cmd_logs ;;
    status)       cmd_status ;;
    *)
        echo -e "${RED}Usage: $0 {foreground|background|install|stop|logs|status}${NC}"
        exit 1
        ;;
esac
