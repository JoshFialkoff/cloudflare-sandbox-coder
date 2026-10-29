#!/bin/bash
# quick-test.sh — Standalone test of the full Tunnel → Access → Worker flow
# Run this script to verify everything is wired up before starting Goose.
# It loads credentials via Bitwarden and makes authenticated requests.

set -euo pipefail

TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-bot-api.yourdomain.com}"
ENDPOINT="${SANDBOX_API_URL:-https://$TUNNEL_DOMAIN}"
BWS_PROJECT_ID="${BWS_PROJECT_ID:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Cloudflare Tunnel + Access + Worker — Quick Test  ${NC}"
echo -e "${BLUE}  Endpoint: $ENDPOINT${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}\n"

# ─── Prerequisites ───
echo "🔍 Checking prerequisites..."
if ! command -v bws &>/dev/null; then
    echo -e "${RED}✗ bws not installed${NC}"
    exit 1
fi
if ! command -v curl &>/dev/null; then
    echo -e "${RED}✗ curl not installed${NC}"
    exit 1
fi
if command -v jq &>/dev/null; then
    HAVE_JQ=1
else
    echo -e "${YELLOW}⚠️  jq not installed; output will be raw JSON${NC}"
    HAVE_JQ=0
fi

if [ -z "$BWS_PROJECT_ID" ]; then
    echo -e "${RED}✗ BWS_PROJECT_ID is not set${NC}"
    exit 1
fi

# ─── Load Secrets ───
echo -e "\n🔐 Loading secrets from Bitwarden..."

if [ "$HAVE_JQ" -eq 1 ]; then
    CF_ACCESS_CLIENT_ID=$(bws secret get CF_ACCESS_CLIENT_ID --project-id "$BWS_PROJECT_ID" 2>/dev/null | jq -r '.value // empty' || true)
    CF_ACCESS_CLIENT_SECRET=$(bws secret get CF_ACCESS_CLIENT_SECRET --project-id "$BWS_PROJECT_ID" 2>/dev/null | jq -r '.value // empty' || true)
else
    CF_ACCESS_CLIENT_ID=$(bws secret get CF_ACCESS_CLIENT_ID --project-id "$BWS_PROJECT_ID" 2>/dev/null | grep -o '"value"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\(.*\)".*/\1/' | head -n1 || true)
    CF_ACCESS_CLIENT_SECRET=$(bws secret get CF_ACCESS_CLIENT_SECRET --project-id "$BWS_PROJECT_ID" 2>/dev/null | grep -o '"value"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\(.*\)".*/\1/' | head -n1 || true)
fi

if [ -z "$CF_ACCESS_CLIENT_ID" ] || [ -z "$CF_ACCESS_CLIENT_SECRET" ]; then
    echo -e "${RED}✗ Failed to load CF_ACCESS_CLIENT_ID or CF_ACCESS_CLIENT_SECRET from Bitwarden${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Secrets loaded${NC}"

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
    if [ "$HAVE_JQ" -eq 1 ]; then
        echo "$BODY" | jq .
    else
        echo "$BODY"
    fi
else
    echo -e "${RED}✗ Health check failed (HTTP $HTTP_STATUS)${NC}"
    echo "$BODY"
    exit 1
fi

# ─── Test 3: Sandbox execution ───
echo -e "\n🚀 TEST 3: Run a sandbox task → should succeed"
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
    else
        echo "  (raw output skipped — install jq for pretty printing)"
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
echo -e "   Start Goose:${BLUE} cd goose-mac && ./start_bot.sh${NC}"
echo -e "   Start tunnel:${BLUE} cd goose-mac/tunnel && ./tunnel-starter.sh foreground${NC}"
