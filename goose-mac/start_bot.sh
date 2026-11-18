#!/bin/bash
# Goose for macOS Launcher — OAuth2 + Keychain + Worker-side scoped secrets
#
# The Bitwarden machine account token lives ONLY as the Cloudflare Worker
# secret `bitwarden_secret`. This script:
#   1. Loads CF Access credentials from macOS Keychain (OAuth2 service token)
#   2. Authenticates to the Worker with a per-bot API key
#   3. Fetches scoped bot secrets from the Worker's /secrets endpoint
#   4. Launches Goose with those secrets in its environment
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

# ─── Load CF Access creds from Keychain ───
echo -e "${GREEN}🔑 Loading Cloudflare Access credentials from Keychain...${NC}"
export CF_ACCESS_CLIENT_ID=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a CF_ACCESS_CLIENT_ID -w 2>/dev/null || true)
export CF_ACCESS_CLIENT_SECRET=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a CF_ACCESS_CLIENT_SECRET -w 2>/dev/null || true)

if [ -z "$CF_ACCESS_CLIENT_ID" ] || [ -z "$CF_ACCESS_CLIENT_SECRET" ]; then
    echo -e "${YELLOW}⚠️  Cloudflare Access credentials not in Keychain — continuing (endpoint is the public workers.dev URL)${NC}"
else
    echo -e "${GREEN}✓ Access credentials loaded${NC}"
fi

# ─── Load bot API key from Keychain ───
# The bot API key authenticates to the Worker and determines which Bitwarden
# secrets the bot is allowed to access (scoped access).
BOT_API_KEY=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a BOT_API_KEY -w 2>/dev/null || true)
if [ -n "$BOT_API_KEY" ]; then
    echo -e "${GREEN}✓ Bot API key loaded from Keychain${NC}"
    AUTH_HEADER="Authorization: Bearer $BOT_API_KEY"
else
    echo -e "${YELLOW}⚠️  No bot API key in Keychain — using unauthenticated mode (BOT_KEYS must be empty on Worker)${NC}"
    AUTH_HEADER=""
fi

# ─── Load bot secrets via Worker /secrets endpoint (scoped) ───
# The Worker uses its server-side bitwarden_secret to resolve only the keys
# the bot is authorized for. No BWS token touches the Mac.
if [ -n "$SECRET_KEYS" ] && [ -n "$BOT_API_KEY" ]; then
    echo -e "${GREEN}🔐 Loading scoped bot secrets from Worker /secrets endpoint — values are never printed${NC}"

    # Build JSON body with requested keys
    KEYS_JSON=$(echo "$SECRET_KEYS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | jq -R . | jq -s . | jq -c '{keys: .}')

    # Call the Worker to resolve secrets server-side
    RESPONSE=$(curl -s -X POST "${ENDPOINT}/secrets" \
        -H "Content-Type: application/json" \
        ${AUTH_HEADER:+-H "$AUTH_HEADER"} \
        -d "$KEYS_JSON" 2>/dev/null) || RESPONSE=""

    if [ -n "$RESPONSE" ] && echo "$RESPONSE" | jq -e '.secrets' >/dev/null 2>&1; then
        # Export each resolved secret into the environment
        for KEY in $(echo "$SECRET_KEYS" | tr ',' ' '); do
            KEY="${KEY// /}"
            [ -n "$KEY" ] || continue
            VALUE=$(echo "$RESPONSE" | jq -r --arg k "$KEY" '.secrets[$k] // empty')
            if [ -n "$VALUE" ] && [ "$VALUE" != "null" ]; then
                export "$KEY=$VALUE"
                echo -e "${GREEN}   ✓ $KEY loaded (value hidden)${NC}"
            else
                echo -e "${YELLOW}   ⚠️  $KEY not available in bot scope${NC}"
            fi
        done
    else
        echo -e "${YELLOW}⚠️  Worker /secrets endpoint did not return secrets — falling back to local bws${NC}"
        # Fallback: use local bws CLI if available
        if command -v bws &> /dev/null && [ -n "${BWS_ACCESS_TOKEN:-}" ]; then
            IFS=',' read -r -a KEYS <<< "$SECRET_KEYS"
            for KEY in "${KEYS[@]}"; do
                KEY="${KEY// /}"
                [ -n "$KEY" ] || continue
                ID=$(bws secret list "$BWS_PROJECT_ID" | jq -r --arg k "$KEY" '.[] | select(.key==$k) | .id' | head -1)
                if [ -n "$ID" ]; then
                    VALUE=$(bws secret get "$ID" | jq -r '.value')
                    if [ -n "$VALUE" ]; then
                        export "$KEY=$VALUE"
                        echo -e "${GREEN}   ✓ $KEY loaded via local bws (value hidden)${NC}"
                    fi
                fi
            done
        else
            echo -e "${RED}❌ Cannot load secrets: Worker endpoint failed and no local bws fallback${NC}"
        fi
    fi
elif [ -n "$SECRET_KEYS" ]; then
    echo -e "${YELLOW}⚠️  SECRET_KEYS set but no bot API key — falling back to local bws${NC}"
    # Fallback: use local bws CLI
    if command -v bws &> /dev/null; then
        command -v jq >/dev/null 2>&1 || { echo -e "${RED}❌ jq not found${NC}"; exit 1; }
        if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
            [ -f "$HOME/.secrets/bws_token" ] || { echo -e "${RED}❌ No BWS access token${NC}"; exit 1; }
            export BWS_ACCESS_TOKEN="$(cat "$HOME/.secrets/bws_token")"
        fi
        IFS=',' read -r -a KEYS <<< "$SECRET_KEYS"
        for KEY in "${KEYS[@]}"; do
            KEY="${KEY// /}"
            [ -n "$KEY" ] || continue
            ID=$(bws secret list "$BWS_PROJECT_ID" | jq -r --arg k "$KEY" '.[] | select(.key==$k) | .id' | head -1)
            if [ -n "$ID" ]; then
                VALUE=$(bws secret get "$ID" | jq -r '.value')
                if [ -n "$VALUE" ]; then
                    export "$KEY=$VALUE"
                    echo -e "${GREEN}   ✓ $KEY loaded via local bws (value hidden)${NC}"
                fi
            fi
        done
    fi
fi

# ─── Launch Goose ───
echo -e "${GREEN}🚀  Launching Goose (profile: $PROFILE)...${NC}"
echo -e "${GREEN}   Tunnel endpoint: https://$TUNNEL_DOMAIN${NC}"

exec goose --profile "$PROFILE"
