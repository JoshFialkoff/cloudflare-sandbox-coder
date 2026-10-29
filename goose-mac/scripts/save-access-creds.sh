#!/bin/bash
# save-access-creds.sh — Store Cloudflare Access Service Token in macOS Keychain
#
# Run ONCE. You will be prompted to paste your CF Access Client ID and Secret.
# They are stored in the macOS Keychain (service "goose-bot") — never in files,
# never in chat, never in git.
#
# Where to get them: Cloudflare Dashboard → Zero Trust → Access → Service Auth
#   → your service token → Client ID / Client Secret.

set -euo pipefail

KEYCHAIN_SERVICE="goose-bot"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}🔐 Storing Cloudflare Access credentials in macOS Keychain${NC}"
echo -e "${YELLOW}   (service: $KEYCHAIN_SERVICE — items are encrypted at rest)${NC}\n"

# ─── Client ID ───
echo "Paste your CF Access CLIENT ID (from Zero Trust → Access → Service Auth):"
read -r -s CLIENT_ID
echo ""
if [ -z "$CLIENT_ID" ]; then
    echo -e "${RED}✗ Empty input${NC}"
    exit 1
fi

# ─── Client Secret ───
echo "Paste your CF Access CLIENT SECRET:"
read -r -s CLIENT_SECRET
echo ""
if [ -z "$CLIENT_SECRET" ]; then
    echo -e "${RED}✗ Empty input${NC}"
    exit 1
fi

# ─── Store (delete old entries first) ───
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a CF_ACCESS_CLIENT_ID 2>/dev/null || true
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a CF_ACCESS_CLIENT_SECRET 2>/dev/null || true

security add-generic-password -s "$KEYCHAIN_SERVICE" -a CF_ACCESS_CLIENT_ID -w "$CLIENT_ID"
security add-generic-password -s "$KEYCHAIN_SERVICE" -a CF_ACCESS_CLIENT_SECRET -w "$CLIENT_SECRET"

echo -e "\n${GREEN}✅ Credentials saved to Keychain.${NC}"
echo "   Verify: security find-generic-password -s $KEYCHAIN_SERVICE -a CF_ACCESS_CLIENT_ID -w | wc -c"
echo ""
echo "   Next:"
echo "     cd goose-mac/tunnel && ./tunnel-starter.sh background   # start tunnel (OAuth2)"
echo "     cd goose-mac/tunnel && ./quick-test.sh                  # verify everything"
echo "     cd goose-mac && ./start_bot.sh                          # launch Goose"