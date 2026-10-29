# Cloudflare Zero Trust Access Policy for Bot Authentication

This guide configures Cloudflare Access to protect your tunnel endpoint so only
your authenticated bots can reach the `sandbox-router`.

## Step 1: Create an Access Application

1. Go to **Cloudflare Zero Trust Dashboard**
2. Navigate to **Access → Applications**
3. Click **Add an Application**
4. Select **Self-hosted**
5. Configure:
   - **Application Name**: `Goose Bot API`
   - **Session Duration**: `24 hours` (or shorter for bots)
   - **Domain**: `bot-api.yourdomain.com`
   - **Domain Type**: `Path` (leave empty for root)

## Step 2: Create an Access Policy

1. Under **Policies**, click **Add a Policy**
2. **Name**: `Bot Service Auth Only`
3. **Action**: `Allow`
4. **Rules**:
   - Add rule: **Selector** = `Service Token`, **Operator** = `Exists`
   - (Optional) Add rule: **Selector** = `IP ranges`, **Operator** = `Is in`, **Value** = `your-server-ip/32`
5. Save the policy.

## Step 3: Create a Service Token

1. Go to **Access → Service Auth**
2. Click **Create Service Token**
3. **Name**: `goose-bot-token`
4. **Duration**: `365 days` (set a calendar reminder to rotate)
5. Save the **Client ID** and **Client Secret** — store them in Bitwarden immediately.

## Step 4: Store Secrets in Bitwarden

In your Bitwarden Secrets Manager project, create:

| Secret Name | Value |
|-------------|-------|
| `CF_ACCESS_CLIENT_ID` | Client ID from Step 3 |
| `CF_ACCESS_CLIENT_SECRET` | Client Secret from Step 3 |

## Step 5: Authenticate from the Bot

Your bot passes these tokens in request headers. The tunnel/Cloudflare edge validates them before forwarding to the `sandbox-router`.

### curl Example

```bash
curl -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
     -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
     https://bot-api.yourdomain.com/health
```

### Goose Configuration

Configure Goose (or your HTTP client) to include these headers on every request to the sandbox API:

```json
{
  "sandbox_api_url": "https://bot-api.yourdomain.com",
  "headers": {
    "CF-Access-Client-Id": "{{env.CF_ACCESS_CLIENT_ID}}",
    "CF-Access-Client-Secret": "{{env.CF_ACCESS_CLIENT_SECRET}}"
  }
}
```

## Step 6: Test and Monitor

1. Attempt a request **without** the headers → expect `403 Forbidden`
2. Attempt with valid headers → expect `200 OK`
3. Monitor in **Zero Trust → Logs → Access**

## Rotating Credentials

1. Generate a new Service Token in Cloudflare Access
2. Update the secrets in Bitwarden
3. Update the bot environment (it will pick up new values on restart via `bws run`)
4. Delete the old Service Token

## Policy Enforcement Checklist

- [ ] Application is configured for `bot-api.yourdomain.com`
- [ ] Policy requires Service Token (not just identity/login)
- [ ] `goose-bot-token` is the only active Service Token for this app
- [ ] No bypass policies exist for the bot API
- [ ] Access Logs show only expected bot traffic
