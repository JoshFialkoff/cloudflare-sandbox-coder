#!/bin/bash
# Example script: How a Goose bot makes requests through the Cloudflare Tunnel
# with Cloudflare Access Service Token authentication.
#
# This script demonstrates the "bot → Tunnel → Sandbox" request flow.
# In practice, Goose (or your agent) would make these HTTP calls programmatically.

set -euo pipefail

TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-bot-api.yourdomain.com}"
ENDPOINT="${SANDBOX_API_URL:-https://$TUNNEL_DOMAIN}"

# ─── Load credentials from Bitwarden (secure, no .env file) ───
echo "🔐 Loading Cloudflare Access credentials from Bitwarden..."
export CF_ACCESS_CLIENT_ID=$(bws secret get CF_ACCESS_CLIENT_ID --project-id "$BWS_PROJECT_ID" | jq -r .value)
export CF_ACCESS_CLIENT_SECRET=$(bws secret get CF_ACCESS_CLIENT_SECRET --project-id "$BWS_PROJECT_ID" | jq -r .value)

if [ -z "$CF_ACCESS_CLIENT_ID" ] || [ -z "$CF_ACCESS_CLIENT_SECRET" ]; then
    echo "❌ Failed to load CF_ACCESS credentials from Bitwarden"
    exit 1
fi

# ─── Example 1: Health Check ───
echo "🩺 Health check..."
curl -s -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
     -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
     "$ENDPOINT/health" | jq .

# ─── Example 2: Run a shell command through the sandbox ───
echo "🚀 Running sandbox task..."
curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  -d '{
    "prompt": "Create a Python script that prints the current date and time, then run it.",
    "sessionId": "demo-session"
  }' | jq .

# ─── Example 3: Read a file from the sandbox ───
echo "📄 Reading generated file..."
curl -s -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
     -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
     "$ENDPOINT/file?session=demo-session&path=/workspace/datetime.py"
