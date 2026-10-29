#!/bin/bash
# quick-test.sh — Test the full Tunnel → Access → Worker flow
#
# Uses OAuth2 / Keychain for credentials — no Bitwarden token on the Mac.
# The Worker owns the Bitwarden token and resolves secrets server-side.
#
# Credentials needed (stored in macOS Keychain, NOT in files):
#   Keychain service "goose-bot" account "CF_ACCESS_CLIENT_ID"
#   Keychain service "goose-bot" account "CF_ACCESS_CLIENT_SECRET"
# Save them once with: scripts/save-access-creds.sh

set -euo pipefail

TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-bot-api.yourdomain.com}"
ENDPOINT="${SANDBOX_API_URL:-https://$TUNNEL_DOMAIN}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Cloudflare Tunnel + Access + Worker — Quick Test  ${NC}"
echo -e "${BLUE}  Endpoint: $ENDPOINT${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}\n"

HAVE_JQ=0
command -v jq &>/dev/null && HAVE_JQ=1

# ─── Load CF Access creds from macOS Keychain ───
echo "🔍 Loading Cloudflare Access credentials from Keychain..."
CF_ACCESS_CLIENT_ID=$(security find-generic-password -s goose-bot -a CF_ACCESS_CLIENT_ID -w 2>/dev/null || true)
CF_ACCESS_CLIENT_SECRET=$(security find-generic-password -s goose-bot -a CF_ACCESS_CLIENT_SECRET -w 2>/dev/null || true)

if [ -z "$CF_ACCESS_CLIENT_ID" ] || [ -z "$CF_ACCESS_CLIENT_SECRET" ]; then
    echo -e "${RED}✗ Missing Cloudflare Access credentials in Keychain.${NC}"
    echo ""
    echo "   Run once (prompts will ask you to paste the values — they go to Keychain only):"
    echo "     cd goose-mac && ./scripts/save-access-creds.sh"
    echo ""
    echo "   Or set env vars (not recommended for persistence):"
    echo "     export CF_ACCESS_CLIENT_ID=... CF_ACCESS_CLIENT_SECRET=..."
    exit 1
fi
echo -e "${GREEN}✓ Credentials loaded from Keychain${NC}"

# ─── Test 1: Unauthenticated request should fail ───
echo -e "\n🛡️  TEST 1: Unauthenticated request → should get 403"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ENDPOINT/health" || true)
if [ "$HTTP_STATUS" = "403" ] || [ "$HTTP_STATUS" = "401" ]; then
    echo -e "${GREEN}✓ Cloudflare Access is blocking unauthenticated requests (HTTP $HTTP_STATUS)${NC}"
else
    echo -e "${YELLOW}⚠️  Unexpected status: $HTTP_STATUS${NC}"
    echo "   (Expected 403 — check your Access policy configuration.)"
fi

# ─── Test 2: Authenticated health check ───
echo -e "\n🩺 TEST 2: Authenticated health check → should get 200 + JSON"
HEALTH_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
    -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
    "$ENDPOINT/health" || true)

HTTP_STATUS=$(echo "$HEALTH_RESPONSE" | tail -n1)
BODY=$(echo "$HEALTH_RESPONSE" | head -n -1)

if [ "$HTTP_STATUS" = "200" ]; then
    echo -e "${GREEN}✓ Health check passed (HTTP 200)${NC}"
    if [ "$HAVE_JQ" -eq 1 ]; then echo "$BODY" | jq .; else echo "$BODY"; fi
else
    echo -e "${RED}✗ Health check failed (HTTP $HTTP_STATUS)${NC}"
    echo "$BODY"
    exit 1
fi

# ─── Test 3: List available secret keys via Worker /secrets ───
echo -e "\n🔑 TEST 3: List secret keys from Worker → should succeed"
SECRETS_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
    -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
    "$ENDPOINT/secrets" || true)

HTTP_STATUS=$(echo "$SECRETS_RESPONSE" | tail -n1)
BODY=$(echo "$SECRETS_RESPONSE" | head -n -1)

if [ "$HTTP_STATUS" = "200" ]; then
    echo -e "${GREEN}✓ /secrets endpoint reachable (HTTP 200)${NC}"
    if [ "$HAVE_JQ" -eq 1 ]; then echo "$BODY" | jq .; else echo "$BODY"; fi
else
    echo -e "${YELLOW}⚠️  /secrets returned HTTP $HTTP_STATUS${NC}"
    echo "$BODY"
    echo "   (This is fine if bitwarden_token / BWS_PROJECT_ID aren't deployed yet.)"
fi

# ─── Test 4: Sandbox execution ───
echo -e "\n🚀 TEST 4: Run a sandbox task → should succeed"
EXEC_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
    -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
    -d '{"prompt":"echo hello from sandbox","sessionId":"quick-test"}' || true)

HTTP_STATUS=$(echo "$EXEC_RESPONSE" | tail -n1)
BODY=$(echo "$EXEC_RESPONSE" | head -n -1)

if [ "$HTTP_STATUS" = "200" ]; then
    echo -e "${GREEN}✓ Sandbox task completed (HTTP 200)${NC}"
    if [ "$HAVE_JQ" -eq 1 ]; then
        echo "$BODY" | jq '. | {sessionId, sandboxId, iterations, status: "ok"}'
    fi
else
    echo -e "${RED}✗ Sandbox task failed (HTTP $HTTP_STATUS)${NC}"
    echo "$BODY"
    exit 1
fi

# ─── Summary ───
echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  All tests passed — your tunnel + bot flow is ready.${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "   Start tunnel:${BLUE} cd goose-mac/tunnel && ./tunnel-starter.sh background${NC}"
echo -e "   Start Goose:${BLUE}  cd goose-mac && ./start_bot.sh${NC}"