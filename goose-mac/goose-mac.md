# Goose Mac Bot Setup Guide

Turn your Mac into a secure AI coding agent that delegates execution to a Cloudflare Sandbox via an encrypted tunnel — with **zero secrets stored on your Mac**.

## The Zero-Secrets Model

| Secret | Location | Why |
|--------|----------|-----|
| Bitwarden Machine Account Token | **Cloudflare Worker secret** (`bitwarden_token`) | Encrypted at rest, never leaves Cloudflare |
| API keys (OpenAI, Anthropic, …) | **Bitwarden Secrets Manager** | Worker resolves them server-side on demand |
| Cloudflare Access Service Token | **macOS Keychain** | Encrypted at rest, one-time paste, never in files |
| Tunnel identity | **`~/.cloudflared/cert.pem`** via `cloudflared tunnel login` | OAuth2 browser flow — no token to share |

> ✅ You've already done the important part: your Bitwarden Machine Account Token is saved
> as the Worker secret `bitwarden_token` in the sandbox-router production settings.

## Prerequisites

```bash
brew install goose cloudflared jq
```

(`bws` is NOT required on the Mac anymore — the Worker owns the token.)

## Step 1: Deploy the Worker with `bitwarden_token`

```bash
cd cloudflare-sandbox-coder
npm install

# Set the secrets (one-time; token value typed at prompt, never stored)
npx wrangler secret put bitwarden_token      # ← your Machine Account Token
npx wrangler secret put BWS_PROJECT_ID        # ← Bitwarden project UUID
npx wrangler secret put ACCESS_TEAM_DOMAIN     # ← e.g. your-team.cloudflareaccess.com
npx wrangler secret put ACCESS_AUD             # ← Access application AUD tag

npx wrangler deploy
```

## Step 2: Configure Cloudflare Access

1. **Create a Service Token** — Zero Trust → Access → Service Auth → Create
   - Name: `goose-bot-token`
2. **Create an Application** — Zero Trust → Access → Applications → Self-hosted
   - Domain: `bot-api.yourdomain.com`
   - Policy: **Allow** when `Service Token exists`
3. See [`tunnel/access-policy.md`](./tunnel/access-policy.md) for details.

## Step 3: One-time Mac Setup (OAuth2 + Keychain)

```bash
# a) OAuth2 tunnel login — browser opens, you sign in. Creates cert.pem.
cd goose-mac/tunnel
./tunnel-starter.sh login

# b) Save CF Access Service Token to Keychain (paste once, encrypted)
cd goose-mac
./scripts/save-access-creds.sh
```

**That's it — no tokens in chat, no .env files, no bws on your Mac.**

## Step 4: Start the Tunnel

```bash
cd goose-mac/tunnel
./tunnel-starter.sh foreground     # try it live (Ctrl+C to stop)
./tunnel-starter.sh background     # runs in background, survives chat close
./tunnel-starter.sh install        # launchd — auto-start on reboot
```

## Step 5: Verify the Full Flow

```bash
cd goose-mac/tunnel
./quick-test.sh
```

Tests:
1. **Unauthenticated request blocked** (403) — Access works
2. **Authenticated health check** (200) — tunnel + Worker reachable
3. **`/secrets` listing** (200) — Worker can talk to Bitwarden
4. **Sandbox execution** (200) — code runs in the container

## Step 6: Launch Goose with Secrets

```bash
cd goose-mac

# List which secrets Goose needs from Bitwarden (comma-separated)
export SECRET_KEYS="OPENAI_API_KEY,ANTHROPIC_API_KEY"

./start_bot.sh
```

The script:
1. Loads CF Access credentials from **Keychain**
2. Calls the Worker's `POST /secrets` endpoint — the Worker uses `bitwarden_token`
   to fetch values from Bitwarden **server-side**
3. Exports them into Goose's environment (memory only)
4. Launches Goose

## Troubleshooting

### `cloudflared tunnel list` → "Error decoding origin cert"
Your `~/.cloudflared/cert.pem` has expired. Fix:
```bash
./tunnel-starter.sh login    # OAuth2 browser flow refreshes it
```

### 403 on all requests
- Run `./scripts/save-access-creds.sh` again (creds may be stale)
- Check the Access policy requires the Service Token
- Rotate the token in Zero Trust → Access → Service Auth if needed

### `/secrets` returns 500
- Confirm `bitwarden_token` secret is deployed: `npx wrangler secret list`
- Confirm `BWS_PROJECT_ID` is set and the token has read access to that project
- Test manually: `curl` the `/secrets` GET endpoint (should list keys)

### Sandbox task fails
- Check `npx wrangler deployments list` — latest deploy includes `/secrets` + `secrets:` support
- Verify the container image built: `npx wrangler deploy --dry-run`

## Security Checklist

- [ ] `bitwarden_token` exists only as a Worker secret (never in git/env/chat)
- [ ] `BWS_ACCESS_TOKEN` has **read-only** access in Bitwarden
- [ ] CF Access policy allows **Service Tokens only**
- [ ] CF Access creds in **Keychain**, not files
- [ ] Tunnel runs via **OAuth2 cert.pem**, no token files
- [ ] Rotate the Service Token quarterly