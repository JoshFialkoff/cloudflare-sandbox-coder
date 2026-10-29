# cloudflare-sandbox-coder

Secure AI coding sandbox on Cloudflare Workers, with Goose Mac bot integration via Cloudflare Tunnels and Bitwarden Secrets Manager.

## Architecture

```
┌─────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Mac Bot    │────▶│ Cloudflare      │────▶│ sandbox-router  │
│  (Goose)    │     │ Tunnel + Access │     │ (Cloudflare     │
│             │     │ (Zero Trust)    │     │  Sandbox)       │
└─────────────┘     └─────────────────┘     └─────────────────┘
       │                                     │
       │         Secrets from                │  Sandboxed
       └────────▶ Bitwarden SM ──────────────┘   Containers
                    (bws CLI)
```

## Quick Start

### 1. Deploy the Sandbox Router

```bash
npm install
npx wrangler deploy
```

### 2. Set up Cloudflare Tunnel + Access

See [`goose-mac/tunnel/`](./goose-mac/tunnel/) for tunnel configuration and Zero Trust policies.

### 3. Run a Mac Bot

```bash
cd goose-mac
export BWS_PROJECT_ID=your-project-id
./start_bot.sh
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `POST` | `/` | Execute shell tasks (JSON or multipart with file upload) |
| `GET` | `/file?session=X&path=Y` | Read a file from a sandbox session |

### POST / Example (JSON)

```bash
curl -X POST https://bot-api.yourdomain.com \
  -H "Content-Type: application/json" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  -d '{"prompt": "Create a Python script that prints \"Hello World\" and run it.", "sessionId": "demo"}'
```

### POST / Example (Multipart with File Upload)

```bash
curl -X POST "https://bot-api.yourdomain.com?sessionId=demo" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  -F "prompt=Update this file to sort output alphabetically" \
  -F "file=@./data.txt"
```

## Mac Bot Setup

See [`goose-mac/goose-mac.md`](./goose-mac/goose-mac.md) for the full Mac bot setup guide.

### Prerequisites

- [Goose](https://block.github.io/goose/) installed (`brew install goose`)
- [Bitwarden Secrets CLI](https://bitwarden.com/help/secrets-manager-cli/) (`brew install bitwarden/tap/bws`)
- [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) (`brew install cloudflared`)

### Tunnel + Bot (Docker)

```bash
cd goose-mac
# Copy and fill in required tokens (never commit)
cp .env.example .env.local  # or use Bitwarden exclusively

# Start the tunnel and bot service
docker compose up -d
```

## Security Model

1. **No inbound open ports** — Cloudflare Tunnel is outbound-only.
2. **Zero Trust Access** — Every request authenticated via Cloudflare Service Tokens.
3. **Secrets isolation** — BWS tokens and API keys never touch disk unencrypted; injected at runtime via `bws run`.
4. **Sandboxed execution** — Code runs inside Cloudflare Sandbox containers, not on the bot host.
5. **No `.env` files for secrets** — `.env*` files are forbidden in this repo. All secrets flow through Bitwarden or encrypted Docker secrets.

## Environment Variables

| Variable | Source | Purpose |
|----------|--------|---------|
| `BWS_ACCESS_TOKEN` | Bitwarden Service Account | Authenticate `bws` CLI |
| `BWS_PROJECT_ID` | Bitwarden Project | Scope secrets to a project |
| `CLOUDFLARE_TUNNEL_TOKEN` | Cloudflare Dash | Authenticate `cloudflared` |
| `CF_ACCESS_CLIENT_ID` | Cloudflare Access | Bot→Tunnel auth (CF-Access-Client-Id header) |
| `CF_ACCESS_CLIENT_SECRET` | Cloudflare Access | Bot→Tunnel auth (CF-Access-Client-Secret header) |
| `LLM_MODEL` | wrangler/secrets | AI model for sandbox reasoning |

## Secrets Management

**This repository does NOT use `.env` files.**

Always inject secrets via Bitwarden Secrets Manager:

```bash
bws run --PROJECT_ID <PROJECT_ID> -- your_command_here
```

For local testing, use macOS Keychain or `bws secret get` directly; never write secrets to files.

## Development

```bash
# Local dev with Wrangler
npx wrangler dev

# Deploy
npx wrangler deploy
```

## Project Structure

```
├── src/index.js          # Sandbox router Worker
├── goose-mac/
│   ├── start_bot.sh        # Mac Goose launcher with BWS
│   ├── docker-compose.yml  # Tunnel + bot service
│   ├── goose-mac.md        # Full Mac setup guide
│   └── tunnel/
│       ├── config.yml      # cloudflared config
│       └── access-policy.md # Zero Trust policy guide
├── Dockerfile              # Sandbox container image
├── wrangler.jsonc          # Worker config
└── package.json
```

## License

Apache 2.0
