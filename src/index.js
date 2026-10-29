import { getSandbox } from "@cloudflare/sandbox";

export { Sandbox } from "@cloudflare/sandbox";

const SYSTEM_PROMPT = `You are an AI coding assistant that executes tasks by writing shell commands.

RULES (mandatory):
1. You MUST output shell commands inside fenced code blocks tagged \`\`\`bash or \`\`\`sh.
2. You MUST NOT output code in any other language block. All work goes through the shell.
3. You can run any command available in a Linux environment: git, curl, python3, node, npm, pip, cat, ls, mkdir, etc.
4. Write files using heredocs or tee. Run scripts with python3 or node.
5. After each command block, the system will execute it and return stdout/stderr.
6. Read the output, then continue with the next step or declare completion.
7. Keep each command block focused — one logical step per block.
8. If a command fails, read the error, fix it, and retry.
9. Do NOT say TASK_COMPLETE until you have seen the output of your commands. Output commands first, wait for results, then say TASK_COMPLETE.

Example interaction:
User: Create a Python script that prints the first 10 Fibonacci numbers and run it.
Assistant:
\`\`\`bash
cat > /workspace/fib.py << 'EOF'
for i in range(10):
    a, b = 0, 1
    for _ in range(i):
        a, b = b, a + b
    print(a)
EOF
\`\`\`
System (stdout): (file created)
Assistant:
\`\`\`bash
python3 /workspace/fib.py
\`\`\`
System (stdout): 0\n1\n1\n2\n3\n5\n8\n13\n21\n34
Assistant: TASK_COMPLETE`;

// ─────────────────────────────────────────────────────────────
// Bitwarden Secrets Manager integration (server-side)
// The BWS machine account token lives ONLY as the Worker secret
// `bitwarden_token` — never on the Mac, never in chat.
// ─────────────────────────────────────────────────────────────
const BWS_API = "https://vault.bitwarden.com/api";

async function bwsListSecrets(env) {
  const resp = await fetch(`${BWS_API}/projects/${env.BWS_PROJECT_ID}/secrets`, {
    headers: { Authorization: `Bearer ${env.bitwarden_token}` },
  });
  if (!resp.ok) {
    throw new Error(`Bitwarden list failed: ${resp.status} ${await resp.text()}`);
  }
  const data = await resp.json();
  return data?.data ?? data ?? [];
}

async function bwsGetSecret(env, secretId) {
  const resp = await fetch(`${BWS_API}/secrets/${secretId}`, {
    headers: { Authorization: `Bearer ${env.bitwarden_token}` },
  });
  if (!resp.ok) {
    throw new Error(`Bitwarden get failed: ${resp.status} ${await resp.text()}`);
  }
  const s = await resp.json();
  return { key: s.key, value: s.value };
}

/** Resolve a list of secret KEYS to a {key: value} map. */
async function resolveSecrets(env, keys) {
  if (!env.bitwarden_token) throw new Error("bitwarden_token secret not configured");
  if (!env.BWS_PROJECT_ID) throw new Error("BWS_PROJECT_ID var not configured");
  const all = await bwsListSecrets(env);
  const byKey = new Map(all.map((s) => [s.key, s.id]));
  const out = {};
  for (const k of keys) {
    const id = byKey.get(k);
    if (id) {
      const s = await bwsGetSecret(env, id);
      out[k] = s.value;
    }
  }
  return out;
}

// ─────────────────────────────────────────────────────────────
// Cloudflare Access JWT verification (defense in depth)
// If ACCESS_TEAM_DOMAIN + ACCESS_AUD are configured, the Worker
// verifies the Cf-Access-Jwt-Assertion header before serving
// secrets. If they're not set, it relies on the tunnel edge.
// ─────────────────────────────────────────────────────────────
function b64urlToBytes(s) {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

async function verifyAccessJwt(request, env) {
  const team = env.ACCESS_TEAM_DOMAIN;
  const aud = env.ACCESS_AUD;
  if (!team || !aud) return true; // not configured → Access edge handles it

  const token = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!token) return false;

  try {
    const [h, p, sig] = token.split(".");
    const header = JSON.parse(atob(h.replace(/-/g, "+").replace(/_/g, "/")));
    const payload = JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/")));

    // Audience + expiry checks
    const auds = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!auds.includes(aud)) return false;
    if (payload.exp * 1000 < Date.now()) return false;

    // Fetch JWKS from the Access team domain
    const jwksResp = await fetch(`https://${team}/cdn-cgi/access/certs`);
    if (!jwksResp.ok) return false;
    const jwks = await jwksResp.json();

    const key = jwks.keys.find((k) => k.kid === header.kid);
    if (!key) return false;

    const cryptoKey = await crypto.subtle.importKey(
      "jwk",
      { kty: key.kty, n: key.n, e: key.e, alg: key.alg },
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"]
    );
    const data = new TextEncoder().encode(`${h}.${p}`);
    return await crypto.subtle.verify("RSASSA-PKCS1-v1_5", cryptoKey, b64urlToBytes(sig), data);
  } catch (e) {
    return false;
  }
}

// ─────────────────────────────────────────────────────────────
// Sandbox helpers
// ─────────────────────────────────────────────────────────────
function extractCodeBlocks(text) {
  const blocks = [];
  const regex = /```(?:bash|sh|shell)?\n([\s\S]*?)```/g;
  let match;
  while ((match = regex.exec(text)) !== null) {
    blocks.push(match[1].trim());
  }
  return blocks;
}

function isTaskComplete(text) {
  return /\bTASK_COMPLETE\b/i.test(text);
}

async function callLLM(messages, env) {
  const model = env.LLM_MODEL || "@cf/meta/llama-3.3-70b-instruct-fp8-fast";
  const response = await env.AI.run(model, {
    messages,
    max_tokens: 2048,
  });

  let content = "";
  if (typeof response === "string") content = response;
  else if (response?.response) content = response.response;
  else if (response?.choices?.[0]?.message?.content) content = response.choices[0].message.content;
  else if (response?.choices?.[0]?.text) content = response.choices[0].text;
  else content = JSON.stringify(response);
  if (typeof content !== "string") content = String(content);

  return content;
}

/**
 * Execute a command in the sandbox, optionally injecting env vars
 * resolved server-side from Bitwarden. The bot never sees the values.
 */
async function execInSandbox(env, sandboxId, command, envVars = {}) {
  const sandbox = getSandbox(env.SANDBOX, sandboxId);

  // Inject secrets as environment variables (server-side only)
  const exports = Object.entries(envVars)
    .map(([k, v]) => `export ${k}=${JSON.stringify(v)}`)
    .join(" && ");
  const finalCommand = exports ? `${exports} && ${command}` : command;

  const result = await sandbox.exec(finalCommand);

  let output = "";
  if (result.stdout) output += result.stdout;
  if (result.stderr) output += (output ? "\n" : "") + `[stderr] ${result.stderr}`;
  if (result.exitCode !== 0) output += (output ? "\n" : "") + `[exit code: ${result.exitCode}]`;

  return output || "(no output)";
}

async function parseMultipart(request, env, sandboxId) {
  const formData = await request.formData();
  const prompt = formData.get("prompt") || "";
  const sessionId = formData.get("sessionId") || "default";

  const files = [];

  for (const [key, value] of formData.entries()) {
    if (key === "prompt" || key === "sessionId") continue;

    if (value && typeof value === "object" && "name" in value && "size" in value) {
      const fileContent = await value.arrayBuffer();
      const filePath = `/workspace/${value.name}`;

      const base64Content = btoa(
        String.fromCharCode(...new Uint8Array(fileContent))
      );

      await execInSandbox(
        env,
        sandboxId,
        `echo '${base64Content}' | base64 -d > '${filePath}'`
      );

      files.push({ name: value.name, path: filePath });
    }
  }

  return { prompt, sessionId, files };
}

// ─────────────────────────────────────────────────────────────
// Worker
// ─────────────────────────────────────────────────────────────
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return new Response(JSON.stringify({ status: "ok" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // ── Secrets endpoints (protected by Cloudflare Access) ──
    if (url.pathname === "/secrets" && request.method === "GET") {
      // List available secret KEYS (not values)
      const ok = await verifyAccessJwt(request, env);
      if (!ok) return new Response(JSON.stringify({ error: "unauthorized" }), { status: 403 });
      try {
        const all = await bwsListSecrets(env);
        return new Response(
          JSON.stringify({ success: true, keys: all.map((s) => s.key).sort() }, null, 2),
          { headers: { "Content-Type": "application/json" } }
        );
      } catch (e) {
        return new Response(JSON.stringify({ success: false, error: e.message }, null, 2), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }

    if (url.pathname === "/secrets" && request.method === "POST") {
      // Resolve secret values by key. Body: { "keys": ["OPENAI_API_KEY"] }
      const ok = await verifyAccessJwt(request, env);
      if (!ok) return new Response(JSON.stringify({ error: "unauthorized" }), { status: 403 });
      try {
        const body = await request.json();
        const keys = body.keys || [];
        const resolved = await resolveSecrets(env, keys);
        return new Response(JSON.stringify({ success: true, secrets: resolved }, null, 2), {
          headers: { "Content-Type": "application/json" },
        });
      } catch (e) {
        return new Response(JSON.stringify({ success: false, error: e.message }, null, 2), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }

    // ── Main task execution ──
    if (url.pathname === "/" && request.method === "POST") {
      const contentType = request.headers.get("Content-Type") || "";
      const maxIterations = parseInt(env.MAX_ITERATIONS || "10", 10);

      let userPrompt, sessionId, uploadedFiles, secretKeys = [];

      if (contentType.includes("multipart/form-data")) {
        sessionId = url.searchParams.get("sessionId") || "default";
        const sandboxId = `${env.SANDBOX_ID_PREFIX || "llm-session"}-${sessionId}`;
        const parsed = await parseMultipart(request, env, sandboxId);
        userPrompt = parsed.prompt;
        sessionId = parsed.sessionId;
        uploadedFiles = parsed.files;

        if (uploadedFiles.length > 0) {
          const fileList = uploadedFiles.map((f) => `- ${f.path}`).join("\n");
          userPrompt = `The following files have been uploaded to the sandbox:\n${fileList}\n\nTask: ${userPrompt}`;
        }
      } else {
        const body = await request.json();
        userPrompt = body.prompt;
        sessionId = body.sessionId || "default";
        uploadedFiles = [];
        secretKeys = body.secrets || [];
      }

      if (!userPrompt) {
        return new Response(JSON.stringify({ error: "Missing 'prompt' field" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        });
      }

      const sandboxId = `${env.SANDBOX_ID_PREFIX || "llm-session"}-${sessionId}`;

      // Resolve requested secrets server-side (bot never sees values)
      let envVars = {};
      if (secretKeys.length > 0) {
        try {
          envVars = await resolveSecrets(env, secretKeys);
          if (secretKeys.length && Object.keys(envVars).length === 0) {
            return new Response(
              JSON.stringify({ error: "No requested secrets found in Bitwarden project", requested: secretKeys }, null, 2),
              { status: 404, headers: { "Content-Type": "application/json" } }
            );
          }
        } catch (e) {
          return new Response(JSON.stringify({ error: e.message }, null, 2), {
            status: 500,
            headers: { "Content-Type": "application/json" },
          });
        }
      }

      const messages = [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: userPrompt },
      ];

      const executionLog = [];

      for (let i = 0; i < maxIterations; i++) {
        const llmResponse = await callLLM(messages, env);
        messages.push({ role: "assistant", content: llmResponse });

        const codeBlocks = extractCodeBlocks(llmResponse);

        if (codeBlocks.length > 0) {
          for (const code of codeBlocks) {
            const output = await execInSandbox(env, sandboxId, code, envVars);
            executionLog.push({ command: code, output });
            messages.push({
              role: "user",
              content: `Command output:\n\n${output}`,
            });
          }
          if (isTaskComplete(llmResponse)) {
            break;
          }
          continue;
        }

        if (isTaskComplete(llmResponse)) {
          break;
        }

        messages.push({
          role: "user",
          content: "You must output shell commands in a ```bash code block. Please continue.",
        });
      }

      return new Response(
        JSON.stringify(
          {
            sessionId,
            sandboxId,
            model: env.LLM_MODEL || "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
            uploadedFiles,
            secretKeys,
            iterations: messages.filter((m) => m.role === "assistant").length,
            finalResponse: messages[messages.length - 1]?.content,
            executionLog,
          },
          null,
          2
        ),
        { headers: { "Content-Type": "application/json" } }
      );
    }

    if (url.pathname === "/file" && request.method === "GET") {
      const sessionId = url.searchParams.get("session") || "default";
      const filePath = url.searchParams.get("path");
      if (!filePath) {
        return new Response(JSON.stringify({ error: "Missing 'path' parameter" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        });
      }

      const sandboxId = `${env.SANDBOX_ID_PREFIX || "llm-session"}-${sessionId}`;
      const output = await execInSandbox(env, sandboxId, `cat '${filePath}'`);

      return new Response(output, {
        headers: { "Content-Type": "text/plain" },
      });
    }

    if (url.pathname === "/favicon.ico") {
      return new Response(null, { status: 404 });
    }

    return new Response(JSON.stringify({
      name: "sandbox-router",
      endpoints: {
        "POST /": "Sandbox mode (shell execution + file upload + server-side secrets)",
        "GET /secrets": "List available secret keys (Access-protected)",
        "POST /secrets": "Resolve secret values by key (Access-protected)",
        "GET /file": "Download file from sandbox",
        "GET /health": "Health check",
      },
      status: "ok"
    }), { headers: { "content-type": "application/json" } });
  },
};