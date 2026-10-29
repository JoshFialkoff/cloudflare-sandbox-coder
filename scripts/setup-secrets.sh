#!/bin/bash
# setup-secrets.sh — ONE command to configure all sandbox-router secrets
#
# Runs interactively: prompts for each value (hidden input for secrets),
# then uploads them to Cloudflare via wrangler and redeploys.
#
# Values can also be pre-set via env vars to skip prompts:
#   BW_TOKEN, BWS_PROJECT_ID, CF_ID, CF_SECRET, ACCESS_AUD, ACCESS_TEAM

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo -e "${BLUE}  sandbox-router — secret setup wizard${NC}"
echo -e "${BLUE}  Everything goes to Cloudflare, not this Mac${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"

ask_hidden() {  # $1 = prompt, $2 = env var name, $3 = optional
  if [ -n "${!2:-}" ]; then
    echo -e "  ${GREEN}✓ $1 (from env)${NC}"
    return 0
  fi
  local value=""
  read -r -s -p "  $1: " value
  echo ""
  if [ -z "$value" ] && [ "${3:-}" != "optional" ]; then
    echo -e "${RED}  ✗ required${NC}"
    return 1
  fi
  if [ -n "$value" ]; then
    export "$2=$value"
  fi
  return 0
}

ask_text() {  # $1 = prompt, $2 = env var name, $3 = default
  if [ -n "${!2:-}" ]; then
    echo -e "  ${GREEN}✓ $1 (from env)${NC}"
    return 0
  fi
  local default="${3:-}"
  local value=""
  read -r -p "  $1${default:+ [$default]}: " value
  if [ -z "$value" ]; then
    value="$default"
  fi
  export "$2=$value"
}

echo ""
echo -e "${YELLOW}Step 1/2 — Credentials${NC}"
ask_hidden "Bitwarden Machine Account Token (starts with 0.)" "BW_TOKEN" || exit 1
ask_text  "Bitwarden Project ID (UUID)" "BWS_PROJECT_ID" || exit 1
ask_hidden "CF Access Service Token — Client ID" "CF_ID" || exit 1
ask_hidden "CF Access Service Token — Client Secret" "CF_SECRET" || exit 1

echo ""
echo -e "${YELLOW}Step 2/2 — Optional Access verification (skip = blank)${NC}"
ask_text  "Access AUD tag (from Access app page)" "ACCESS_AUD"
ask_text  "Access team domain" "ACCESS_TEAM" "goose.cloudflareaccess.com"

# ─── Upload secrets (only ones with values) ───
upload_secret() {  # $1 = wrangler name, $2 = env var name
  if [ -n "${!2:-}" ]; then
    echo -e "  ${BLUE}→ uploading secret $1...${NC}"
    echo "${!2}" | npx wrangler secret put "$1" >/dev/null 2>&1
  fi
}

echo ""
echo -e "${YELLOW}Uploading secrets to Cloudflare...${NC}"
upload_secret bitwarden_token        BW_TOKEN
upload_secret cf_access_client_id    CF_ID
upload_secret cf_access_client_secret CF_SECRET
upload_secret ACCESS_AUD             ACCESS_AUD

# ─── Plain vars (BWS_PROJECT_ID + ACCESS_TEAM_DOMAIN) ───
if [ -n "$BWS_PROJECT_ID" ]; then
  echo -e "  ${BLUE}→ setting var BWS_PROJECT_ID...${NC}"
  echo "$BWS_PROJECT_ID" | npx wrangler secret put BWS_PROJECT_ID >/dev/null 2>&1
fi
if [ -n "${ACCESS_TEAM:-}" ]; then
  echo -e "  ${BLUE}→ setting var ACCESS_TEAM_DOMAIN...${NC}"
  echo "$ACCESS_TEAM" | npx wrangler secret put ACCESS_TEAM_DOMAIN >/dev/null 2>&1
fi

# ─── Redeploy ───
echo ""
echo -e "${YELLOW}Redeploying Worker (no container)...${NC}"
npx wrangler deploy --containers-rollout=none 2>&1 | tail -8

echo ""
echo -e "${GREEN}✅ Done! Verify:${NC}"
echo "   npx wrangler secret list"
echo ""
echo -e "${BLUE}Next: cd goose-mac/tunnel && ./tunnel-starter.sh background${NC}"