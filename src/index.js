import { DurableObject } from "cloudflare:workers";

// ═══════════════════════════════════════════════════════════════════════════════
// SandboxV2 Durable Object — manages a Cloudflare Container instance
// ═══════════════════════════════════════════════════════════════════════════════

export class SandboxV2 extends DurableObject {
  async ensureRunning() {
    const container = this.ctx.container;
    if (!container) throw new Error("Container binding is not configured");
    if (!container.running) {
      container.start({ image: container.images.sandbox, enableInternet: true });
    }
  }

  async setEnvVars(vars) {
    const stored = (await this.ctx.storage.get("envVars")) || {};
    Object.assign(stored, vars);
    await this.ctx.storage.put("envVars", stored);
  }

  async getEnvVars() {
    return (await this.ctx.storage.get("envVars")) || {};
  }

  async clearEnvVars() {
    await this.ctx.storage.delete("envVars");
  }

  async exec(command) {
    await this.ensureRunning();
    const envVars = (await this.ctx.storage.get("envVars")) || {};
    let fullCommand = command;
    if (Object.keys(envVars).length > 0) {
      const exports = Object.entries(envVars)
        .map(([k, v]) => `export ${k}=${shellQuote(v)}`)
        .join("; ");
      fullCommand = `${exports}; ${command}`;
    }
    const process = await this.ctx.container.exec(["sh", "-c", fullCommand]);
    const { exitCode, stdout, stderr } = await process.output();
    const decoder = new TextDecoder();
    return {
      exitCode,
      stdout: stdout ? decoder.decode(stdout) : "",
      stderr: stderr ? decoder.decode(stderr) : "",
    };
  }
}

function shellQuote(v) {
  return `'${String(v).replace(/'/g, "'\\''")}'`;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Bot Authentication — per-bot API keys for isolated container access
// ═══════════════════════════════════════════════════════════════════════════════
//
// BOT_KEYS:       JSON map of botId → apiKey   (e.g. {"ads-bot":"key123"})
// BOT_SECRET_SCOPES: JSON map of botId → ["SECRET_KEY1", "SECRET_KEY2"]
//
// If BOT_KEYS is unset or empty, authentication is disabled (backward-compatible).
// If BOT_KEYS is set, all requests must include `Authorization: Bearer <apiKey>`.

function getBotKeys(env) {
  try { return JSON.parse(env.BOT_KEYS || "{}"); } catch { return {}; }
}

function getBotScopes(env) {
  try { return JSON.parse(env.BOT_SECRET_SCOPES || "{}"); } catch { return {}; }
}

function authenticateBot(request, env) {
  const botKeys = getBotKeys(env);
  if (Object.keys(botKeys).length === 0) {
    // No bot keys configured — backward-compatible mode, use "default" bot
    return "default";
  }
  const authHeader = request.headers.get("Authorization") || "";
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const apiKey = match[1];
  for (const [botId, key] of Object.entries(botKeys)) {
    if (key === apiKey) return botId;
  }
  return null;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Scoped Bitwarden Secret Resolution
// ═══════════════════════════════════════════════════════════════════════════════
//
// Instead of passing the raw bitwarden_secret (BWS machine account token) into
// the sandbox as a persistent env var, the Worker resolves only the secrets the
// bot is authorized for and injects those values. The bitwarden_secret is used
// inline in a single bws command and is never stored in the sandbox environment.

async function resolveScopedSecrets(env, sandboxId, botId) {
  const scopes = getBotScopes(env)[botId] || [];
  if (scopes.length === 0) return {};

  const stub = getSandboxStub(env, sandboxId);
  const token = env.bitwarden_secret;
  if (!token) return {};

  const projectId = env.BWS_PROJECT_ID;
  if (!projectId) return {};

  // Run bws in the sandbox with the token inline (not stored as env var)
  const listCmd = `BWS_ACCESS_TOKEN=${shellQuote(token)} bws secret list ${projectId} --output json 2>/dev/null`;
  const listResult = await stub.exec(listCmd);

  let secrets;
  try {
    secrets = JSON.parse(listResult.stdout || "");
  } catch {
    return {};
  }
  if (!Array.isArray(secrets)) return {};

  const envVars = {};
  for (const secret of secrets) {
    if (!scopes.includes(secret.key)) continue;
    if (secret.value) {
      envVars[secret.key] = secret.value;
    } else {
      // Value not in list response — fetch individually
      const getCmd = `BWS_ACCESS_TOKEN=${shellQuote(token)} bws secret get ${shellQuote(secret.id)} --output json 2>/dev/null`;
      const getResult = await stub.exec(getCmd);
      try {
        const secretData = JSON.parse(getResult.stdout || "");
        if (secretData.value) envVars[secret.key] = secretData.value;
      } catch { /* skip on error */ }
    }
  }

  return envVars;
}

// ═══════════════════════════════════════════════════════════════════════════════
// System Prompt — enforce shell-based code execution
// ═══════════════════════════════════════════════════════════════════════════════

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
9. When the task is fully complete, respond with exactly: TASK_COMPLETE

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

// ═══════════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════════

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

// Safe base64 encoding for large files (avoids call stack overflow)
function uint8ToBase64(bytes) {
  let binary = "";
  const chunkSize = 8192;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

// ═══════════════════════════════════════════════════════════════════════════════
// LLM call
// ═══════════════════════════════════════════════════════════════════════════════

async function callLLM(messages, env) {
  const model = env.LLM_MODEL || "@cf/meta/llama-3.3-70b-instruct-fp8-fast";
  const response = await env.AI.run(model, { messages, max_tokens: 2048 });
  let content = "";
  if (typeof response === "string") content = response;
  else if (response?.response) content = response.response;
  else if (response?.choices?.[0]?.message?.content) content = response.choices[0].message.content;
  else if (response?.choices?.[0]?.text) content = response.choices[0].text;
  else content = JSON.stringify(response);
  if (typeof content !== "string") content = String(content);
  return content;
}

// ═══════════════════════════════════════════════════════════════════════════════
// SandboxV2 access via Durable Object RPC
// ═══════════════════════════════════════════════════════════════════════════════

function getSandboxStub(env, sandboxId) {
  const id = env.SANDBOX.idFromName(sandboxId);
  return env.SANDBOX.get(id);
}

// Per-bot sandbox ID — each bot gets its own isolated container
function getSandboxId(env, botId, sessionId) {
  const prefix = env.SANDBOX_ID_PREFIX || "llm-session";
  return `${prefix}-${botId}-${sessionId}`;
}

// Resolve scoped secrets and inject into the sandbox (bitwarden_secret is NOT stored)
async function setupSandboxEnv(env, sandboxId, botId) {
  if (!botId) return;
  const scopedSecrets = await resolveScopedSecrets(env, sandboxId, botId);
  if (Object.keys(scopedSecrets).length > 0) {
    const stub = getSandboxStub(env, sandboxId);
    await stub.setEnvVars(scopedSecrets);
  }
}

async function execInSandbox(env, sandboxId, command) {
  const stub = getSandboxStub(env, sandboxId);
  const result = await stub.exec(command);
  let output = "";
  if (result.stdout) output += result.stdout;
  if (result.stderr) output += (output ? "\n" : "") + `[stderr] ${result.stderr}`;
  if (result.exitCode !== 0) output += (output ? "\n" : "") + `[exit code: ${result.exitCode}]`;
  return output || "(no output)";
}

// ═══════════════════════════════════════════════════════════════════════════════
// File upload helper
// ═══════════════════════════════════════════════════════════════════════════════

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
      const base64Content = uint8ToBase64(new Uint8Array(fileContent));
      await execInSandbox(env, sandboxId, `echo -n '${base64Content}' | base64 -d > '${filePath}'`);
      files.push({ name: value.name, path: filePath });
    }
  }
  return { prompt, sessionId, files };
}

// ═══════════════════════════════════════════════════════════════════════════════
// MCP server — expose sandbox as MCP tools (JSON-RPC 2.0, no external deps)
// ═══════════════════════════════════════════════════════════════════════════════

const MCP_TOOLS = [
  {
    name: "exec",
    description: "Execute a shell command inside an isolated Linux sandbox. The sandbox has scoped Bitwarden secrets available as env vars (not the raw BWS token). Git, curl, python3, node, npm, pip, etc. are available.",
    inputSchema: {
      type: "object",
      properties: {
        command: { type: "string", description: "The shell command to execute" },
        sessionId: { type: "string", description: "SandboxV2 session ID for persistence (defaults to 'default')" },
      },
      required: ["command"],
    },
  },
  {
    name: "read_file",
    description: "Read the contents of a file from the sandbox filesystem.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Absolute path to the file to read" },
        sessionId: { type: "string", description: "SandboxV2 session ID (defaults to 'default')" },
      },
      required: ["path"],
    },
  },
  {
    name: "write_file",
    description: "Write content to a file in the sandbox filesystem.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Absolute path to write to" },
        content: { type: "string", description: "Text content to write" },
        sessionId: { type: "string", description: "SandboxV2 session ID (defaults to 'default')" },
      },
      required: ["path", "content"],
    },
  },
];

async function callMcpTool(name, args, env, botId) {
  const sessionId = args.sessionId || "default";
  const sandboxId = getSandboxId(env, botId, sessionId);
  if (name === "exec") {
    await setupSandboxEnv(env, sandboxId, botId);
    const output = await execInSandbox(env, sandboxId, args.command);
    return { content: [{ type: "text", text: output }] };
  }
  if (name === "read_file") {
    const output = await execInSandbox(env, sandboxId, `cat '${args.path}'`);
    return { content: [{ type: "text", text: output }] };
  }
  if (name === "write_file") {
    // Use a heredoc with a unique delimiter to safely write content
    const delimiter = `GOOSE_WRITE_${Date.now()}_${Math.random().toString(36).slice(2)}`;
    const safeContent = args.content.replace(/\r\n/g, "\n");
    await execInSandbox(env, sandboxId, `cat > '${args.path}' << '${delimiter}'\n${safeContent}\n${delimiter}`);
    return { content: [{ type: "text", text: `File written to ${args.path}` }] };
  }
  return { isError: true, content: [{ type: "text", text: `Unknown tool: ${name}` }] };
}

async function handleMcp(request, env, botId) {
  const method = request.method;
  if (method === "GET") {
    const stream = new ReadableStream({
      start(controller) { controller.enqueue(new TextEncoder().encode(": keepalive\n\n")); },
    });
    return new Response(stream, {
      headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" },
    });
  }
  if (method === "DELETE") { return new Response(null, { status: 202 }); }
  if (method !== "POST") { return new Response("Method not allowed", { status: 405 }); }
  let message;
  try { message = await request.json(); } catch {
    return new Response(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }), { headers: { "Content-Type": "application/json" } });
  }
  if (Array.isArray(message)) {
    const results = [];
    for (const msg of message) { const res = await processJsonRpc(msg, env, botId); if (res) results.push(res); }
    return new Response(JSON.stringify(results), { headers: { "Content-Type": "application/json" } });
  }
  const response = await processJsonRpc(message, env, botId);
  if (!response) { return new Response(null, { status: 202 }); }

  const headers = { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Mcp-Session-Id": crypto.randomUUID() };
  return new Response("event: message\ndata: " + JSON.stringify(response) + "\n\n", { headers });
}

async function processJsonRpc(message, env, botId) {
  const { id, method, params } = message;
  if (id === undefined || id === null) { return null; }
  let result;
  switch (method) {
    case "initialize":
      result = { protocolVersion: "2026-07-28", capabilities: { tools: { listChanged: false } }, serverInfo: { name: "sandbox-router", version: "2.0.0" } };
      break;
    case "notifications/initialized": return { jsonrpc: "2.0", id, result: {} };
    case "tools/list": result = { tools: MCP_TOOLS }; break;
    case "tools/call":
      try { result = await callMcpTool(params.name, params.arguments || {}, env, botId); }
      catch (err) { result = { isError: true, content: [{ type: "text", text: `Error: ${err.message}` }] }; }
      break;
    case "ping": result = {}; break;
    default: return { jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } };
  }
  return { jsonrpc: "2.0", id, result };
}

// ═══════════════════════════════════════════════════════════════════════════════
// /secrets endpoint — list and resolve scoped Bitwarden secrets for a bot
// ═══════════════════════════════════════════════════════════════════════════════
//
// GET  /secrets          → list available secret keys (not values) for the bot
// POST /secrets          → resolve specific secrets (body: {"keys": ["KEY1", ...]})
//                          returns {"secrets": {"KEY1": "value1", ...}}

async function handleSecrets(request, env, botId) {
  const scopes = getBotScopes(env)[botId] || [];

  if (request.method === "GET") {
    return new Response(JSON.stringify({
      botId,
      availableSecrets: scopes,
    }), { headers: { "Content-Type": "application/json" } });
  }

  if (request.method === "POST") {
    let body;
    try { body = await request.json(); } catch {
      return new Response(JSON.stringify({ error: "Invalid JSON body" }), { status: 400, headers: { "Content-Type": "application/json" } });
    }
    const requestedKeys = body.keys || [];
    // Only allow keys within the bot's scope
    const allowedKeys = requestedKeys.filter((k) => scopes.includes(k));
    if (allowedKeys.length === 0) {
      return new Response(JSON.stringify({ error: "No requested keys are within the bot's scope", botId, scopes }), { status: 403, headers: { "Content-Type": "application/json" } });
    }

    // Use a transient sandbox to resolve secrets
    const sandboxId = getSandboxId(env, botId, "secret-resolution");
    const scopedSecrets = await resolveScopedSecrets(env, sandboxId, botId);
    const result = {};
    for (const key of allowedKeys) {
      if (scopedSecrets[key]) result[key] = scopedSecrets[key];
    }
    return new Response(JSON.stringify({ secrets: result }), { headers: { "Content-Type": "application/json" } });
  }

  return new Response("Method not allowed", { status: 405 });
}

// ═══════════════════════════════════════════════════════════════════════════════
// Main Worker
// ═══════════════════════════════════════════════════════════════════════════════

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // Health check — no auth required
    if (url.pathname === "/health") {
      return new Response(JSON.stringify({
        status: "ok",
        version: "2.0.0",
        authEnabled: Object.keys(getBotKeys(env)).length > 0,
      }), { headers: { "Content-Type": "application/json" } });
    }

    // Authenticate all other endpoints
    const botId = authenticateBot(request, env);
    if (!botId) {
      return new Response(JSON.stringify({ error: "Unauthorized — provide a valid bot API key via Authorization: Bearer <key>" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    // MCP server
    if (url.pathname === "/mcp") {
      return handleMcp(request, env, botId);
    }

    // Secrets endpoint — list/resolve scoped Bitwarden secrets
    if (url.pathname === "/secrets") {
      return handleSecrets(request, env, botId);
    }

    // Main sandbox execution endpoint
    if (url.pathname === "/" && request.method === "POST") {
      const contentType = request.headers.get("Content-Type") || "";
      const maxIterations = parseInt(env.MAX_ITERATIONS || "10", 10);
      let userPrompt, sessionId, uploadedFiles;

      if (contentType.includes("multipart/form-data")) {
        sessionId = url.searchParams.get("sessionId") || "default";
        const sandboxId = getSandboxId(env, botId, sessionId);
        await setupSandboxEnv(env, sandboxId, botId);
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
      }

      if (!userPrompt) {
        return new Response(JSON.stringify({ error: "Missing 'prompt' field" }), { status: 400, headers: { "Content-Type": "application/json" } });
      }

      const sandboxId = getSandboxId(env, botId, sessionId);
      await setupSandboxEnv(env, sandboxId, botId);

      const messages = [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: userPrompt },
      ];
      const executionLog = [];

      for (let i = 0; i < maxIterations; i++) {
        const llmResponse = await callLLM(messages, env);
        messages.push({ role: "assistant", content: llmResponse });
        if (isTaskComplete(llmResponse)) { break; }
        const codeBlocks = extractCodeBlocks(llmResponse);
        if (codeBlocks.length === 0) {
          messages.push({ role: "user", content: "You must output shell commands in a \`\`\`bash code block. Please continue." });
          continue;
        }
        for (const code of codeBlocks) {
          const output = await execInSandbox(env, sandboxId, code);
          executionLog.push({ command: code, output });
          messages.push({ role: "user", content: `Command output:\n\n${output}` });
        }
      }

      return new Response(JSON.stringify({
        botId,
        sessionId,
        sandboxId,
        model: env.LLM_MODEL || "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
        uploadedFiles,
        iterations: messages.filter((m) => m.role === "assistant").length,
        finalResponse: messages[messages.length - 1]?.content,
        executionLog,
      }, null, 2), { headers: { "Content-Type": "application/json" } });
    }

    // File download from sandbox
    if (url.pathname === "/file" && request.method === "GET") {
      const sessionId = url.searchParams.get("session") || "default";
      const filePath = url.searchParams.get("path");
      if (!filePath) { return new Response(JSON.stringify({ error: "Missing 'path' parameter" }), { status: 400, headers: { "Content-Type": "application/json" } }); }
      const sandboxId = getSandboxId(env, botId, sessionId);
      const output = await execInSandbox(env, sandboxId, `cat '${filePath}'`);
      return new Response(output, { headers: { "Content-Type": "text/plain" } });
    }

    if (url.pathname === "/favicon.ico") { return new Response(null, { status: 404 }); }

    // Service info
    return new Response(JSON.stringify({
      name: "sandbox-router",
      version: "2.0.0",
      endpoints: {
        "POST /": "SandboxV2 mode (shell execution + file upload)",
        "GET /file": "Download file from sandbox",
        "GET /health": "Health check",
        "POST /mcp": "MCP server (Streamable HTTP)",
        "GET /secrets": "List scoped secret keys for authenticated bot",
        "POST /secrets": "Resolve scoped secrets for authenticated bot",
      },
      auth: Object.keys(getBotKeys(env)).length > 0 ? "enabled" : "disabled (backward-compatible)",
      status: "ok",
    }), { headers: { "Content-Type": "application/json" } });
  },
};
