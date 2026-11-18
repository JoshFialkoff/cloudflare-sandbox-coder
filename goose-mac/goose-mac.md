# Goose Mac Bot Setup Guide

Turn your Mac into a secure AI coding agent that delegates execution to a Cloudflare Sandbox via an encrypted tunnel — with **zero secrets stored on your Mac**.

## The Zero-Secrets Model (v2 — Per-Bot Scoped Access)

| Secret | Location | Why |
|--------|----------|-----|
| Bitwarden Machine Account Token | **Cloudflare Worker secret** (`bitwarden_secret`) | Encrypted at rest, never leaves Cloudflare, never passed to sandboxes |
| Per-Bot API Key | **macOS Keychain** | Authenticates bot to Worker, determines scoped secret access |
| API keys (OpenAI, Anthropic, …) | **Bitwarden Secrets Manager** | Worker resolves only scoped keys server-side |
| Cloudflare Access Service Token | **macOS Keychain** | Encrypted at rest, one-time paste, never in files |
| Tunnel identity | **`~/.cloudflared/cert.pem`** via `cloudflared tunnel login` | OAuth2 browser flow — no token to share |

### What changed in v2

**Before (v1):** The raw `bitwarden_secret` (BWS machine account token) was passed into every sandbox as `BWS_ACCESS_TOKEN` / `BWS_TOKEN` env vars. Any code running in the sandbox could use this token to access **all** secrets in the Bitwarden project.

**After (v2):** The Worker resolves only the secrets a bot is authorized for and injects those **values** into the sandbox. The `bitwarden_secret` is used inline in a single `bws` command to fetch secrets, then is never stored in the sandbox environment. Each bot gets its own isolated container, and only sees the secrets it's scoped to access.

## Prerequisites

```bash
brew install goose cloudflared jq
```

## Step 1: Configure Bot Keys and Scopes

Set these as Worker vars (via `wrangler.jsonc` or dashboard):

```jsonc
// wrangler.jsonc vars
{
  "BOT_KEYS": "{\"ads-bot\":\"key_abc123\",\"seo-bot\":\"key_def456\"}",
  "BOT_SECRET_SCOPES": "{\"ads-bot\":[\"GOOGLE_ADS_CLIENT_ID\",\"GOOGLE_ADS_CLIENT_SECRET\",\"GOOGLE_ADS_DEVELOPER_TOKEN\",\"GOOGLE_ADS_REFRESH_TOKEN\"],\"seo-bot\":[\"OPENAI_API_KEY\"]}"
}
```

- **BOT_KEYS**: JSON map of `botId → apiKey`. If empty `{}`, auth is disabled (backward-compatible).
- **BOT_SECRET_SCOPES**: JSON map of `botId → [allowed secret keys]`. Only these keys will be resolved from Bitwarden for that bot.

For production, set these as Worker secrets instead of vars:
```bash
npx wrangler secret put BOT_KEYS
npx wrangler secret put BOT_SECRET_SCOPES
```

## Step 2: Deploy the Worker

```bash
cd cloudflare-sandbox-coder
npm install

# Set the secrets (one-time; token value typed at prompt, never stored)
npx wrangler secret put bitwarden_token      # ← your Machine Account Token

npx wrangler deploy
```

## Step 3: Configure Cloudflare Access

1. **Create a Service Token** — Zero Trust → Access → Service Auth → Create
   - Name: `goose-bot-token`
2. **Create an Application** — Zero Trust → Access → Applications → Self-hosted
   - Domain: `bot-api.yourdomain.com`
   - Policy: **Allow** when `Service Token exists`
3. See [`tunnel/access-policy.md`](./tunnel/access-policy.md) for details.

## Step 4: One-time Mac Setup

```bash
# a) OAuth2 tunnel login — browser opens, you sign in. Creates cert.pem.
cd goose-mac/tunnel
./tunnel-starter.sh login

# b) Save CF Access Service Token to Keychain (paste once, encrypted)
cd goose-mac
./scripts/save-access-creds.sh

# c) Save bot API key to Keychain (the key you configured in BOT_KEYS)
security add-generic-password -s goose-bot -a BOT_API_KEY -w "key_abc123"
```

## Step 5: Start the Tunnel

```bash
cd goose-mac/tunnel
./tunnel-starter.sh foreground     # try it live (Ctrl+C to stop)
./tunnel-starter.sh background     # runs in background, survives chat close
./tunnel-starter.sh install        # launchd — auto-start on reboot
```

## Step 6: Verify the Full Flow

```bash
cd goose-mac/tunnel
./quick-test.sh
```

## Step 7: Launch Goose with Scoped Secrets

```bash
cd goose-mac

# List which secrets Goose needs (comma-separated, must be in bot's scope)
export SECRET_KEYS="OPENAI_API_KEY,ANTHROPIC_API_KEY"

./start_bot.sh
```

The script:
1. Loads CF Access credentials from **Keychain**
2. Loads bot API key from **Keychain**
3. Calls the Worker's `POST /secrets` endpoint — the Worker uses `bitwarden_secret`
   to fetch only scoped values from Bitwarden **server-side**
4. Exports them into Goose's environment (memory only)
5. Launches Goose

## API Reference (v2)

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `POST /` | POST | Bot API key | Sandbox execution (shell commands + LLM) |
| `GET /file` | GET | Bot API key | Download file from sandbox |
| `GET /health` | GET | None | Health check (shows auth status) |
| `POST /mcp` | POST | Bot API key | MCP server (Streamable HTTP) |
| `GET /secrets` | GET | Bot API key | List available secret keys for bot |
| `POST /secrets` | POST | Bot API key | Resolve scoped secrets (body: `{"keys": [...]}`) |

## Troubleshooting

### 401 Unauthorized
- Bot API key not set or incorrect
- Check `BOT_KEYS` var/secret on the Worker
- Ensure keychain has the right key: `security find-generic-password -s goose-bot -a BOT_API_KEY -w`

### Secrets not loading
- Check `BOT_SECRET_SCOPES` includes the requested keys for the bot
- Check `bitwarden_secret` is deployed: `npx wrangler secret list`
- Verify BWS project ID matches: `BWS_PROJECT_ID` var

### Sandbox task fails
- Check `npx wrangler deployments list`
- Verify the container image built: `npx wrangler deploy --dry-run`

## Security Checklist

- [ ] `bitwarden_secret` exists only as a Worker secret (never in git/env/chat/sandbox)
- [ ] Per-bot API keys stored in **Keychain**, not files
- [ ] `BOT_SECRET_SCOPES` limits each bot to only the secrets it needs
- [ ] `BWS_ACCESS_TOKEN` has **read-only** access in Bitwarden
- [ ] CF Access policy allows **Service Tokens only**
- [ ] CF Access creds in **Keychain**, not files
- [ ] Tunnel runs via **OAuth2 cert.pem**, no token files
- [ ] Rotate the Service Token quarterly
