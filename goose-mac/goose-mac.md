# Goose Mac Bot Setup Guide

Turn your Mac into a secure AI coding agent that delegates execution to a Cloudflare Sandbox via an encrypted tunnel, with all secrets managed by Bitwarden.

## What You Get

- Goose AI running natively on macOS
- All execution pushed to isolated Cloudflare Sandbox containers
- Zero secrets stored on your Mac (everything via Bitwarden)
- Network access locked down via Cloudflare Zero Trust

## Prerequisites

Install the following via Homebrew:

```bash
# Goose AI agent
brew install goose

# Bitwarden Secrets Manager CLI
brew install bitwarden/tap/bws

# Cloudflare Tunnel client
brew install cloudflared
```

## Step 1: Bitwarden Secrets Manager Setup

1. Create a Service Account in your Bitwarden Organization:
   - Bitwarden Admin Console → Secrets Manager → Service Accounts
   - Create service account, give it read access to your project

2. Create secrets for your bot:
   | Secret Name | Example Value |
   |-------------|---------------|
   | `OPENAI_API_KEY` | sk-... |
   | `CF_ACCESS_CLIENT_ID` | xxxxxxxx.access |
   | `CF_ACCESS_CLIENT_SECRET` | xxxxxxxxxxxxxxxxxxxxxxxx |
   | `CLOUDFLARE_TUNNEL_TOKEN` | eyJ... |

3. Copy the **Service Account Access Token** (starts with `0.`) — this is your `BWS_ACCESS_TOKEN`.

4. Note your **Project ID** (UUID format) — this is your `BWS_PROJECT_ID`.

## Step 2: Configure Cloudflare Tunnel

1. In the Cloudflare Dashboard, create a Tunnel:
   - Zero Trust → Networks → Tunnels → Create
   - Name: `goose-bot-tunnel`
   - Connector: Docker (copy the token)

2. Save the tunnel token as `CLOUDFLARE_TUNNEL_TOKEN` in Bitwarden.

3. Create a Public Hostname:
   - Subdomain: `bot-api`
   - Domain: `yourdomain.com`
   - Service: `HTTP://localhost:8787` (or wherever your sandbox-router is)

4. Apply Zero Trust Access (see [`tunnel/access-policy.md`](./tunnel/access-policy.md)).

## Step 3: Configure `cloudflared` on Mac

```bash
# Authenticate (one-time)
cloudflared tunnel login

# Create and route a tunnel
cloudflared tunnel create goose-bot-tunnel
cloudflared tunnel route dns goose-bot-tunnel bot-api.yourdomain.com

# Copy config
cp tunnel/config.yml ~/.cloudflared/config.yml
# Edit ~/.cloudflared/config.yml with your tunnel UUID

# Run
cd goose-mac
bws run -- cloudflared tunnel run goose-bot-tunnel
```

Or use Docker Compose (recommended for production):

```bash
export BWS_ACCESS_TOKEN=$(bws secret get <ACCESS_TOKEN_SECRET_ID> | jq -r .value)
export CLOUDFLARE_TUNNEL_TOKEN=$(bws secret get <TUNNEL_TOKEN_SECRET_ID> | jq -r .value)
docker compose up -d
```

## Step 4: Launch the Goose Bot

### Option A: Direct Launch (Development)

```bash
export BWS_PROJECT_ID="your-project-uuid"
./start_bot.sh
```

This script:
1. Validates `bws` and `goose` are installed
2. Loads all secrets from Bitwarden into the environment
3. Launches Goose with those secrets available
4. Configures Goose to use the tunnel endpoint for sandbox execution

### Option B: Docker Launch (Production)

```bash
cd goose-mac
docker compose up -d bot-service
```

The bot service automatically:
1.pull the tunnel token from Bitwarden
2. Authenticates to Cloudflare Access
3. Starts Goose in a containerized environment

## Step 5: Verify the Tunnel + Access Flow

```bash
# Test that your bot can reach the sandbox through the tunnel
curl -H "CF-Access-Client-Id: $(bws secret get CF_ACCESS_CLIENT_ID | jq -r .value)" \
     -H "CF-Access-Client-Secret: $(bws secret get CF_ACCESS_CLIENT_SECRET | jq -r .value)" \
     https://bot-api.yourdomain.com/health
```

Expected: `{"status":"ok"}`

## Step 6: Use Goose with the Sandbox

Configure Goose to use your sandbox-router as its execution backend. In Goose settings or via environment:

```bash
export SANDBOX_API_URL="https://bot-api.yourdomain.com"
export CF_ACCESS_CLIENT_ID="$(bws secret get CF_ACCESS_CLIENT_ID | jq -r .value)"
export CF_ACCESS_CLIENT_SECRET="$(bws secret get CF_ACCESS_CLIENT_SECRET | jq -r .value)"
```

When Goose needs to run code, it will POST to the sandbox-router through the tunnel, sending the Cloudflare Access headers to authenticate.

## Troubleshooting

### `bws` not found
```bash
brew install bitwarden/tap/bws
```

### `goose` not found
```bash
brew install goose
```

### Tunnel not connecting
Check `cloudflared tunnel info goose-bot-tunnel` and confirm the connector is healthy.

### Access denied (403)
- Verify your `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` are current
- Check Zero Trust Logs for blocked requests
- Ensure the Service Token is included in your Access policy

### Secrets not loading
```bash
# Test BWS connectivity
bws secret list --project-id <PROJECT_ID>
```

## Security Checklist

- [ ] No `.env` files committed to git
- [ ] `BWS_ACCESS_TOKEN` has **read-only** access (no write)
- [ ] Cloudflare Access policy restricts to Service Auth only
- [ ] Tunnel token rotated quarterly
- [ ] Service Tokens rotated quarterly
- [ ] `start_bot.sh` file permissions: `chmod 700 start_bot.sh`

## Files Reference

| File | Purpose |
|------|---------|
| `start_bot.sh` | Launch Goose with BWS-injected secrets |
| `docker-compose.yml` | Production tunnel + bot orchestration |
| `tunnel/config.yml` | `cloudflared` configuration |
| `tunnel/access-policy.md` | Zero Trust policy setup steps |
