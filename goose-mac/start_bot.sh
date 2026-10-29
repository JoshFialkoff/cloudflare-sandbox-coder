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
BWS_PROJECT_ID="${BWS_PROJECT_ID:-}"           # optional; only used for var names
TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-bot-api.yourdomain.com}"
ENDPOINT="${SANDBOX_API_URL:-https://$TUNNEL_DOMAIN}"
SECRET_KEYS="${SECRET_KEYS:-}"                  # comma-separated, e.g. OPENAI_API_KEY,ANTHROPIC_API_KEY
KEYCHAIN_SERVICE="goose-bot"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    echo -e "${RED}❌ Cloudflare Access credentials not found in Keychain.${NC}"
    echo "   Run once: $SCRIPT_DIR/scripts/save-access-creds.sh"
    exit 1
fi
echo -e "${GREEN}✓ Access credentials loaded${NC}"

# ─── Fetch bot secrets from the Worker (server-side Bitwarden) ───
if [ -n "$SECRET_KEYS" ]; then
    echo -e "${GREEN}🔐 Fetching bot secrets from Worker /secrets endpoint...${NC}"

    IFS=',' read -r -a KEYS <<< "$SECRET_KEYS"
    BODY_KEYS=$(printf '"%s",' "${KEYS[@]}" | sed 's/,$//')

    RESPONSE=$(curl -s -X POST "$ENDPOINT/secrets" \
        -H "Content-Type: application/json" \
        -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
        -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
        -d "{\"keys\": [$BODY_KEYS]}" || true)

    # Check success flag
    if ! echo "$RESPONSE" | grep -q '"success": true'; then
        echo -e "${RED}❌ Worker /secrets failed:${NC}"
        echo "$RESPONSE"
        exit 1
    fi

    # Export each secret into the environment (values stay in memory only)
    if command -v jq &>/dev/null; then
        for KEY in "${KEYS[@]}"; do
            VALUE=$(echo "$RESPONSE" | jq -r ".secrets[\"$KEY\"] // empty")
            if [ -n "$VALUE" ]; then
                export "$KEY=$VALUE"
                echo -e "${GREEN}   ✓ $KEY loaded (value hidden)${NC}"
            else
                echo -e "${YELLOW}   ⚠️  $KEY not found in Bitwarden project${NC}"
            fi
        done
    else
        echo -e "${YELLOW}⚠️  jq not installed — secrets fetched but not exported.${NC}"
        echo "   Install jq: brew install jq"
        exit 1
    fi
fi

# ─── Launch Goose ───
echo -e "${GREEN}🚀  Launching Goose (profile: $PROFILE)...${NC}"
echo -e "${GREEN}   Tunnel endpoint: https://$TUNNEL_DOMAIN${NC}"

exec goose --profile "$PROFILE"