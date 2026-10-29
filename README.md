# 🤖 Cloudflare Sandbox Coder + Goose Mac Bot

A secure agent-to-agent execution pipeline where:
- A **Goose assistant** on your Mac prompts a **Cloudflare Worker** running in a **Cloudflare Sandbox**
- **Code execution happens in fully isolated containers** — no code ever runs on your machine
- **Zero Trust access control** via Cloudflare Access Service Tokens
- **No secrets on your Mac** — the Bitwarden machine account token lives only as the Cloudflare Worker secret `bitwarden_token`, and the Worker resolves secrets server-side

---

## 🔐 Security Model (Zero Secrets on the Mac)

| Secret | Where it lives | How it's used |
|--------|----------------|---------------|
| Bitwarden Machine Account Token (`bitwarden_token`) | **Cloudflare Worker secret** (encrypted at rest, never leaves Cloudflare) | Worker calls Bitwarden Secrets Manager API server-side |
| All API keys (OpenAI, Anthropic, etc.) | **Bitwarden Secrets Manager** | Resolved server-side by the Worker on demand |
| Cloudflare Access Service Token | **macOS Keychain** (encrypted, one-time setup) | Bot authenticates to the tunnel with CF-Access headers |
| Tunnel identity | **`~/.cloudflared/cert.pem`** (from `cloudflared tunnel login` — OAuth2 browser flow) | `cloudflared` authenticates the outbound tunnel connection |

**Nothing is stored in `.env` files, shell history, or chat.**

---

## 📐 Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              YOUR MAC                                    │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐              │
│  │   Goose Bot  │───▶│  Cloudflare  │───▶│ Cloudflare   │              │
│  │  (Keychain)  │    │   Tunnel*    │    │  Access*     │              │
│  └──────────────┘    └──────────────┘    └──────┬───────┘              │
│                                                │                       │
│                *OAuth2 browser login            │  *Service Tokens   │
│                *outbound-only, no open ports    │                     │
└────────────────────────────────────────────────┼───────────────────────┘
                                                 │
                          ┌──────────────────────┼─────────────────────┐
                          │      CLOUDFLARE      │                     │
                          │      SERVICE WORKER  │                     │
                          │  ┌───────────────────┴──┐                  │
                          │  │ secret: bitwarden_token │               │
                          │  │      ↓ BWS API (server-side)            │
                          │  │ Bitwarden Secrets Manager                │
                          │  │      ↓ env vars                          │
                          │  │ Cloudflare Sandbox (bot container)       │
                          │  │   code runs here ✓ (not on your Mac)     │
                          │  └───────────────────────────────────────── │
                          └──────────────────────────────────────────────┘
```

**Flow:** Bot → Tunnel (OAuth2 cert) → Access (Service Token) → Worker → BWS (server-side token) → Sandbox env vars → code executes in the container.

---

## 🚀 Quick Start

### 1. Store the Bitwarden token as a Worker secret

```bash
# The Machine Account Token goes ONLY to Cloudflare (encrypted at rest)
npx wrangler secret put bitwarden_token
# ✓ already done in your setup (https://dash.cloudflare.com/.../workers/services/view/sandbox-router)

# Set the Bitwarden project ID + Access verification vars
npx wrangler secret put BWS_PROJECT_ID       # your Bitwarden project UUID
npx wrangler secret put ACCESS_TEAM_DOMAIN   # e.g. your-team.cloudflareaccess.com
npx wrangler secret put ACCESS_AUD           # Access application AUD tag
```

### 2. Deploy the Worker

```bash
npm install
npx wrangler deploy
```

### 3. One-time Mac setup (OAuth2 + Keychain — no tokens in chat)

```bash
# a) OAuth2 browser login for the tunnel (creates ~/.cloudflared/cert.pem)
cd goose-mac/tunnel && ./tunnel-starter.sh login

# b) Store Cloudflare Access Service Token in Keychain (paste once, encrypted)
cd goose-mac && ./scripts/save-access-creds.sh
```

### 4. Start the tunnel

| Command | What it does | Survives new chat? |
|---|---|---|
| `./tunnel-starter.sh foreground` | Runs now, blocks terminal | ❌ No — Ctrl+C to stop |
| `./tunnel-starter.sh background` | Runs via `nohup` in background | ✅ Yes, while Mac is awake |
| `./tunnel-starter.sh install` | Installs launchd service | ✅ Yes — auto-start on reboot |

### 5. Verify, then run Goose

```bash
./quick-test.sh          # 4 tests: unauth blocked, health, /secrets, sandbox
cd goose-mac && ./start_bot.sh   # fetches secrets via Worker, launches Goose
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

Control: `launchctl load|unload ~/Library/LaunchAgents/com.cloudflare.goosebot.tunnel.plist`

---

## 🔬 Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `POST` | `/` | Execute sandbox tasks (JSON or multipart + file upload) |
| `GET` | `/secrets` | List available secret keys (Access-protected) |
| `POST` | `/secrets` | Resolve secret values by key (Access-protected) |
| `GET` | `/file?session=X&path=Y` | Read a file from a sandbox session |

### Run a task with server-side secrets

```bash
curl -X POST https://bot-api.yourdomain.com \
  -H "Content-Type: application/json" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  -d '{
    "prompt": "Use the OPENAI_API_KEY env var to call the API",
    "sessionId": "demo",
    "secrets": ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
  }'
```

The Worker resolves those keys from Bitwarden **server-side** and injects them as env vars into the sandbox. The bot never sees the values.

---

## 📂 Directory Structure

```
cloudflare-sandbox-coder/
├── src/index.js                # Worker: sandbox + /secrets + Access JWT check
├── wrangler.jsonc               # Wrangler config (BWS_PROJECT_ID, ACCESS_*)
├── Dockerfile                   # Container (Cloudflare Sandbox)
├── .gitignore                   # Blocks ALL .env files
├── README.md
└── goose-mac/
    ├── start_bot.sh             # Launches Goose; secrets via Worker /secrets
    ├── docker-compose.yml       # Container: tunnel + bot
    ├── .env.example             # Non-secret config only
    ├── goose-mac.md             # Full step-by-step setup guide
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

## ⚠️  Security Checklist

- [ ] **No `.env` files with secrets** — `.gitignore` blocks them all
- [ ] **Bitwarden token only in Cloudflare Worker secrets** (`bitwarden_token`)
- [ ] **OAuth2 for the tunnel** — `cloudflared tunnel login`, no token in files
- [ ] **Cloudflare Access** with Service Token auth — blocks unauthorized requests
- [ ] **CF Access creds in macOS Keychain**, never in chat or git
- [ ] **Outbound-only tunnel** — no open ports on your Mac
- [ ] **Sandboxed execution** — code runs in ephemeral containers