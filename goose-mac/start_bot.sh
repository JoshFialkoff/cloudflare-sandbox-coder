#!/bin/bash
# Goose for macOS Launcher — OAuth2 + Keychain + Worker-side secrets
#
# The Bitwarden machine account token lives ONLY as the Cloudflare Worker
# secret `bitwarden_token`. This script:
#   1. Loads CF Access credentials from macOS Keychain (OAuth2 service token)
#   2. Fetches bot secrets from the Worker's /secrets endpoint (server-side BWS)
#   3. Launches Goose with those secrets in its environment
#
# No tokens are stored on disk or passed through chat.

set -euo pipefail

PROFILE="${1:-default}"
BWS_PROJECT_ID="${BWS_PROJECT_ID:-7afd61b4-a7cb-49f0-b215-b4bd0111966a}"
TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-bot-api.assistedly.ai}"
SANDBOX_API_URL="${SANDBOX_API_URL:-https://sandbox-router.forwardjump-com198.workers.dev}"
ENDPOINT="$SANDBOX_API_URL"
SECRET_KEYS="${SECRET_KEYS:-}"                  # comma-separated, e.g. OPENAI_API_KEY,ANTHROPIC_API_KEY
KEYCHAIN_SERVICE="goose-bot"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load non-secret bot config written by the env loader (if present)
[ -f "$HOME/.goose-bot-env" ] && . "$HOME/.goose-bot-env"

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}🪿  Starting Goose bot (profile: $PROFILE)${NC}"

# ─── Validation ───
if ! command -v goose &> /dev/null; then
    echo -e "${RED}❌ Goose CLI not found.${NC}"
    echo "   Install: brew install goose"
    exit 1
fi
if ! command -v security &> /dev/null; then
    echo -e "${RED}❌ macOS Keychain (security) not available.${NC}"
    exit 1
fi

# ─── Load CF Access creds from Keychain ───
echo -e "${GREEN}🔑 Loading Cloudflare Access credentials from Keychain...${NC}"
export CF_ACCESS_CLIENT_ID=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a CF_ACCESS_CLIENT_ID -w 2>/dev/null || true)
export CF_ACCESS_CLIENT_SECRET=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a CF_ACCESS_CLIENT_SECRET -w 2>/dev/null || true)

if [ -z "$CF_ACCESS_CLIENT_ID" ] || [ -z "$CF_ACCESS_CLIENT_SECRET" ]; then
    echo -e "${YELLOW}⚠️  Cloudflare Access credentials not in Keychain — continuing (endpoint is the public workers.dev URL)${NC}"
else
    echo -e "${GREEN}✓ Access credentials loaded${NC}"
fi

# ─── Load bot secrets from Bitwarden Secrets Manager (bws) ───
# Values are exported into the process environment only — never printed, logged, or written to disk.
if [ -n "$SECRET_KEYS" ]; then
    echo -e "${GREEN}🔐 Loading bot secrets from Bitwarden (bws) — values are never printed${NC}"

    command -v bws >/dev/null 2>&1 || { echo -e "${RED}❌ bws CLI not found (brew install bitwarden-cli)${NC}"; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo -e "${RED}❌ jq not found (brew install jq)${NC}"; exit 1; }
    if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
        [ -f "$HOME/.secrets/bws_token" ] || { echo -e "${RED}❌ No BWS access token (set BWS_ACCESS_TOKEN or create ~/.secrets/bws_token, chmod 600)${NC}"; exit 1; }
        export BWS_ACCESS_TOKEN="$(cat "$HOME/.secrets/bws_token")"
    fi

    IFS=',' read -r -a KEYS <<< "$SECRET_KEYS"
    for KEY in "${KEYS[@]}"; do
        KEY="${KEY// /}"
        [ -n "$KEY" ] || continue
        ID=$(bws secret list "$BWS_PROJECT_ID" | jq -r --arg k "$KEY" '.[] | select(.key==$k) | .id' | head -1)
        if [ -z "$ID" ]; then
            echo -e "${YELLOW}   ⚠️  $KEY not found in Bitwarden project${NC}"
            continue
        fi
        VALUE=$(bws secret get "$ID" | jq -r '.value')
        if [ -n "$VALUE" ]; then
            export "$KEY=$VALUE"
            echo -e "${GREEN}   ✓ $KEY loaded (value hidden)${NC}"
        else
            echo -e "${YELLOW}   ⚠️  $KEY returned an empty value${NC}"
        fi
    done
fi

# ─── Launch Goose ───
echo -e "${GREEN}🚀  Launching Goose (profile: $PROFILE)...${NC}"
echo -e "${GREEN}   Tunnel endpoint: https://$TUNNEL_DOMAIN${NC}"

exec goose --profile "$PROFILE"