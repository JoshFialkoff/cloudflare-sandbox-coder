#!/bin/bash
# Goose for macOS Launcher with Bitwarden Secrets Manager
# Usage: ./start_bot.sh [profile]
# Requires: bws (Bitwarden CLI), goose (Goose AI)

set -euo pipefail

PROFILE="${1:-default}"
BWS_PROJECT_ID="${BWS_PROJECT_ID:-}"
TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-bot-api.yourdomain.com}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ─── Validation ───
echo -e "${GREEN}🪿  Starting Goose bot (profile: $PROFILE)${NC}"

if ! command -v bws &> /dev/null; then
    echo -e "${RED}❌ Bitwarden Secrets CLI (bws) not found.${NC}"
    echo "   Install: brew install bitwarden/tap/bws"
    exit 1
fi

if ! command -v goose &> /dev/null; then
    echo -e "${RED}❌ Goose CLI not found.${NC}"
    echo "   Install: brew install goose"
    exit 1
fi

if [ -z "$BWS_PROJECT_ID" ]; then
    echo -e "${YELLOW}⚠️  BWS_PROJECT_ID not set.${NC}"
    echo "   Set it with: export BWS_PROJECT_ID=your-project-uuid"
    exit 1
fi

# ─── Secrets Check ───
echo -e "${GREEN}🔐  Loading secrets from Bitwarden Secrets Manager...${NC}"
if ! bws secret list --project-id "$BWS_PROJECT_ID" &> /dev/null; then
    echo -e "${RED}❌ Failed to list secrets from project $BWS_PROJECT_ID${NC}"
    echo "   Verify your BWS_ACCESS_TOKEN is set and has access to this project."
    exit 1
fi

# ─── Optional: Pre-fetch critical secrets for validation ───
# Uncomment to validate required secrets exist before launching:
# export CF_ACCESS_CLIENT_ID=$(bws secret get CF_ACCESS_CLIENT_ID --project-id "$BWS_PROJECT_ID" | jq -r .value)
# export CF_ACCESS_CLIENT_SECRET=$(bws secret get CF_ACCESS_CLIENT_SECRET --project-id "$BWS_PROJECT_ID" | jq -r .value)
# if [ -z "$CF_ACCESS_CLIENT_ID" ] || [ -z "$CF_ACCESS_CLIENT_SECRET" ]; then
#     echo -e "${RED}❌ Cloudflare Access credentials missing in Bitwarden.${NC}"
#     exit 1
# fi

# ─── Launch Goose via BWS ───
# bws run -- injects all secrets as environment variables, then executes the command.
# Secrets are never written to disk and are only in memory during the Goose session.

echo -e "${GREEN}🚀  Launching Goose (profile: $PROFILE)...${NC}"
echo -e "${GREEN}   Tunnel endpoint: https://$TUNNEL_DOMAIN${NC}"

exec bws run --project "$BWS_PROJECT_ID" -- goose --profile "$PROFILE"
