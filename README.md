# 🤖 Cloudflare Sandbox Coder + Goose Mac Bot (v2)

A secure agent-to-agent execution pipeline where:
- A **Goose assistant** on your Mac prompts a **Cloudflare Worker** running in a **Cloudflare Sandbox**
- **Code execution happens in fully isolated containers** — no code ever runs on your machine
- **Per-bot isolated containers** — each bot gets its own sandbox with scoped access
- **Zero Trust access control** via Cloudflare Access Service Tokens + per-bot API keys
- **No secrets on your Mac** — the Bitwarden machine account token lives only as the Cloudflare Worker secret `bitwarden_secret`, and the Worker resolves only scoped secrets server-side
- **Scoped Bitwarden access** — each bot only sees the secrets it's authorized for, never the raw BWS token

---

## 🔐 Security Model v2 (Per-Bot Scoped Access)

| Secret | Where it lives | How it's used |
|--------|----------------|---------------|
| Bitwarden Machine Account Token (`bitwarden_secret`) | **Cloudflare Worker secret** (encrypted at rest, never leaves Cloudflare) | Worker calls `bws` in sandbox inline to resolve scoped secrets — token is **never stored** in sandbox env |
| Per-Bot API Key | **macOS Keychain** (encrypted, one-time setup) | Authenticates bot to Worker, determines which Bitwarden secrets the bot can access |
| API keys (OpenAI, Google Ads, etc.) | **Bitwarden Secrets Manager** | Worker resolves only the keys in the bot's `BOT_SECRET_SCOPES` — values injected into sandbox, raw token is not |
| Cloudflare Access Service Token | **macOS Keychain** (encrypted, one-time setup) | Bot authenticates to the tunnel with CF-Access headers |
| Tunnel identity | **`~/.cloudflared/cert.pem`** (from `cloudflared tunnel login` — OAuth2 browser flow) | `cloudflared` authenticates the outbound tunnel connection |

### What changed in v2

| Aspect | v1 | v2 |
|--------|----|----|
| BWS token in sandbox | Stored as persistent `BWS_ACCESS_TOKEN` env var | Used inline in one `bws` command, never stored |
| Secret scope | All secrets accessible to all bots | Per-bot `BOT_SECRET_SCOPES` controls which keys each bot sees |
| Authentication | CF Access only | CF Access + per-bot API key (`BOT_KEYS`) |
| Container isolation | Shared by session ID | Per-bot + per-session (`${prefix}-${botId}-${sessionId}`) |
| `/secrets` endpoint | Not implemented | `GET` lists keys, `POST` resolves values (scoped per bot) |

**Nothing is stored in `.env` files, shell history, or chat.**

---

## 📐 Architecture (v2)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              YOUR MAC                                    │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐              │
│  │   Goose Bot  │───▶│  Cloudflare  │───▶│ Cloudflare   │              │
│  │  (Keychain)  │    │   Tunnel*    │    │  Access*     │              │
│  │  + Bot API   │    └──────────────┘    └──────┬───────┘              │
│  │    Key       │                                │                       │
│  └──────────────┘                                │  *Service Tokens   │
│                *OAuth2 browser login             │                     │
│                *outbound-only, no open ports     │                     │
└──────────────────────────────────────────────────┼─────────────────────┘
                                                   │
                          ┌────────────────────────┼─────────────────────┐
                          │      CLOUDFLARE        │                     │
                          │      SERVICE WORKER    │                     │
                          │  ┌─────────────────────┴──┐                  │
                          │  │ secret: bitwarden_secret│                 │
                          │  │      ↓ bws (inline, not stored)           │
                          │  │ Bitwarden Secrets Manager                  │
                          │  │      ↓ scoped values only                 │
                          │  │ Per-Bot Sandbox Container                  │
                          │  │   (botId-scoped env vars)                  │
                          │  │   code runs here ✓ (not on your Mac)      │
                          │  │   BWS token NEVER in sandbox env           │
                          │  └────────────────────────────────────────── │
                          └────────────────────────────────────────────────┘
```

**Flow:** Bot (API key) → Tunnel (OAuth2 cert) → Access (Service Token) → Worker (authenticate bot key) → resolve scoped secrets via `bws` (inline token) → inject values into per-bot sandbox → code executes in the container.

---

## 🚀 Quick Start

### 1. Configure bot keys and secret scopes

Set these as Worker vars or secrets:

```jsonc
// BOT_KEYS — map of botId → apiKey
{"ads-bot": "key_abc123", "seo-bot": "key_def456"}

// BOT_SECRET_SCOPES — map of botId → [allowed Bitwarden secret keys]
{
  "ads-bot": ["GOOGLE_ADS_CLIENT_ID", "GOOGLE_ADS_CLIENT_SECRET", "GOOGLE_ADS_DEVELOPER_TOKEN", "GOOGLE_ADS_REFRESH_TOKEN"],
  "seo-bot": ["OPENAI_API_KEY"]
}
```

```bash
# Set via wrangler secrets (recommended for production)
npx wrangler secret put BOT_KEYS
npx wrangler secret put BOT_SECRET_SCOPES

# Or set as vars in wrangler.jsonc for development
```

### 2. Store the Bitwarden token as a Worker secret

```bash
npx wrangler secret put bitwarden_secret     # ← your Machine Account Token
# Already done in your setup
```

### 3. Deploy the Worker

```bash
npm install
npx wrangler deploy
```

### 4. One-time Mac setup (OAuth2 + Keychain — no tokens in chat)

```bash
# a) OAuth2 browser login for the tunnel (creates ~/.cloudflared/cert.pem)
cd goose-mac/tunnel && ./tunnel-starter.sh login

# b) Store Cloudflare Access Service Token in Keychain (paste once, encrypted)
cd goose-mac && ./scripts/save-access-creds.sh

# c) Store bot API key in Keychain (the key you configured in BOT_KEYS)
security add-generic-password -s goose-bot -a BOT_API_KEY -w "key_abc123"
```

### 5. Start the tunnel

| Command | What it does | Survives new chat? |
|--------|------|-------------|
| `./tunnel-starter.sh foreground` | Runs now, blocks terminal | No — Ctrl+C to stop |
| `./tunnel-starter.sh background` | Runs via `nohup` in background | Yes, while Mac is awake |
| `./tunnel-starter.sh install` | Installs launchd service | Yes — auto-start on reboot |

### 6. Verify, then run Goose

```bash
./quick-test.sh          # tests: unauth blocked, health, /secrets, sandbox
cd goose-mac && ./start_bot.sh   # fetches scoped secrets via Worker, launches Goose
```

---

## 🔆 Starting the Tunnel (in this chat / new chats)

### → In this chat (foreground, for testing)

```bash
cd goose-mac/tunnel
./tunnel-starter.sh foreground
```

### → Survives closing the window (background)

```bash
cd goose-mac/tunnel
./tunnel-starter.sh background     # nohup — keeps running
./tunnel-starter.sh status         # check alive
./tunnel-starter.sh logs           # last 50 lines
./tunnel-starter.sh stop           # when done
```

### → In new chats / after reboot (launchd)

```bash
cd goose-mac/tunnel
./tunnel-starter.sh install        # LaunchAgent — auto-starts on boot
```

---

## 🔬 Endpoints (v2)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET` | `/health` | None | Health check (shows auth status) |
| `POST` | `/` | Bot API key | Execute sandbox tasks (JSON or multipart + file upload) |
| `GET` | `/secrets` | Bot API key | List available secret keys for the authenticated bot |
| `POST` | `/secrets` | Bot API key | Resolve scoped secrets (body: `{"keys": ["KEY1", ...]}`) |
| `GET` | `/file?session=X&path=Y` | Bot API key | Read a file from a sandbox session |
| `POST` | `/mcp` | Bot API key | MCP server (Streamable HTTP) |

### Run a task with scoped secrets

```bash
curl -X POST https://bot-api.yourdomain.com \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $BOT_API_KEY" \
  -d '{
    "prompt": "Use the GOOGLE_ADS_DEVELOPER_TOKEN env var to call the API",
    "sessionId": "demo"
  }'
```

The Worker authenticates the bot API key, resolves only the secrets in the bot's scope from Bitwarden **server-side**, and injects them as env vars into the bot's isolated sandbox. The bot never sees the BWS token or secrets outside its scope.

---

## 📂 Directory Structure

```
cloudflare-sandbox-coder/
├── src/index.js                # Worker v2: per-bot auth, scoped secrets, sandbox
├── wrangler.jsonc               # Wrangler config (BOT_KEYS, BOT_SECRET_SCOPES)
├── Dockerfile                   # Container (Cloudflare Sandbox + bws + python3)
├── .gitignore                   # Blocks ALL .env files
├── README.md
└── goose-mac/
    ├── start_bot.sh             # v2: scoped secrets via Worker /secrets endpoint
    ├── docker-compose.yml       # Container: tunnel + bot
    ├── .env.example             # Non-secret config only
    ├── goose-mac.md             # Full step-by-step setup guide (v2)
    ├── scripts/
    │   ├── save-access-creds.sh # CF Access Service Token → Keychain (once)
    │   └── tunnel_request_example.sh   # Demo API calls
    └── tunnel/
        ├── tunnel-starter.sh    # OAuth2 login + start/stop/install/status
        ├── quick-test.sh        # Verify full flow before using
        ├── config.yml           # cloudflared config (cert-based)
        └── access-policy.md     # Zero Trust policy guide
```

---

## ⚠️  Security Checklist (v2)

- [ ] **No `.env` files with secrets** — `.gitignore` blocks them all
- [ ] **`bitwarden_secret` only in Cloudflare Worker secrets** — never in sandbox env
- [ ] **Per-bot API keys** in `BOT_KEYS` — stored in Keychain on Mac, not files
- [ ] **Per-bot secret scopes** in `BOT_SECRET_SCOPES` — each bot only gets its authorized secrets
- [ ] **BWS token never stored in sandbox** — used inline for one `bws` command, then gone
- [ ] **OAuth2 for the tunnel** — `cloudflared tunnel login`, no token in files
- [ ] **Cloudflare Access** with Service Token auth — blocks unauthorized requests
- [ ] **CF Access creds + bot API key in macOS Keychain**, never in chat or git
- [ ] **Outbound-only tunnel** — no open ports on your Mac
- [ ] **Sandboxed execution** — code runs in ephemeral, per-bot isolated containers
