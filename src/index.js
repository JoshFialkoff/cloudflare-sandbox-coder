import { getSandbox } from "@cloudflare/sandbox";

// Export the Sandbox Durable Object class — required by Wrangler
export { Sandbox } from "@cloudflare/sandbox";

// ─── System Prompt: Enforce shell-based code execution ───────────────────────

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

// ─── Helpers ──────────────────────────────────────────────────────────────────

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

// ─── LLM call ─────────────────────────────────────────────────────────────────

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

// ─── Sandbox execution ───────────────────────────────────────────────────────

async function setupSandboxEnv(env, sandboxId) {
  const sandbox = getSandbox(env.SANDBOX, sandboxId);
  const envVars = {};
  if (env.bitwarden_secret) {
    envVars.BWS_ACCESS_TOKEN = env.bitwarden_secret;
    envVars.BWS_TOKEN = env.bitwarden_secret;
  }
  if (Object.keys(envVars).length > 0) {
    await sandbox.setEnvVars(envVars);
  }
}

async function execInSandbox(env, sandboxId, command) {
  const sandbox = getSandbox(env.SANDBOX, sandboxId);
  const result = await sandbox.exec(command);
  let output = "";
  if (result.stdout) output += result.stdout;
  if (result.stderr) output += (output ? "\n" : "") + `[stderr] ${result.stderr}`;
  if (result.exitCode !== 0) output += (output ? "\n" : "") + `[exit code: ${result.exitCode}]`;
  return output || "(no output)";
}

// ─── File upload helper ───────────────────────────────────────────────────────

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
      const base64Content = btoa(String.fromCharCode(...new Uint8Array(fileContent)));
      await execInSandbox(env, sandboxId, `echo '${base64Content}' | base64 -d > '${filePath}'`);
      files.push({ name: value.name, path: filePath });
    }
  }
  return { prompt, sessionId, files };
}

// ─── MCP server: expose sandbox as MCP tools (JSON-RPC 2.0, no external deps) ─

const MCP_TOOLS = [
  {
    name: "exec",
    description: "Execute a shell command inside an isolated Linux sandbox. The sandbox has BWS_ACCESS_TOKEN and BWS_TOKEN env vars set for Bitwarden Secrets Manager access. Git, curl, python3, node, npm, pip, etc. are available.",
    inputSchema: {
      type: "object",
      properties: {
        command: { type: "string", description: "The shell command to execute" },
        sessionId: { type: "string", description: "Sandbox session ID for persistence (defaults to 'default')" },
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
        sessionId: { type: "string", description: "Sandbox session ID (defaults to 'default')" },
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
        sessionId: { type: "string", description: "Sandbox session ID (defaults to 'default')" },
      },
      required: ["path", "content"],
    },
  },
];

async function callMcpTool(name, args, env) {
  const sessionId = args.sessionId || "default";
  const sandboxId = `${env.SANDBOX_ID_PREFIX || "llm-session"}-${sessionId}`;
  if (name === "exec") {
    await setupSandboxEnv(env, sandboxId);
    const output = await execInSandbox(env, sandboxId, args.command);
    return { content: [{ type: "text", text: output }] };
  }
  if (name === "read_file") {
    const output = await execInSandbox(env, sandboxId, `cat '${args.path}'`);
    return { content: [{ type: "text", text: output }] };
  }
  if (name === "write_file") {
    const base64Content = btoa(args.content);
    await execInSandbox(env, sandboxId, `echo '${base64Content}' | base64 -d > '${args.path}'`);
    return { content: [{ type: "text", text: `File written to ${args.path}` }] };
  }
  return { isError: true, content: [{ type: "text", text: `Unknown tool: ${name}` }] };
}

async function handleMcp(request, env) {
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
    for (const msg of message) { const res = await processJsonRpc(msg, env); if (res) results.push(res); }
    return new Response(JSON.stringify(results), { headers: { "Content-Type": "application/json" } });
  }
  const response = await processJsonRpc(message, env);
  if (!response) { return new Response(null, { status: 202 }); }

  const headers = { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Mcp-Session-Id": crypto.randomUUID() };
  return new Response("event: message\ndata: " + JSON.stringify(response) + "\n\n", { headers });
}

async function processJsonRpc(message, env) {
  const { id, method, params } = message;
  if (id === undefined || id === null) { return null; }
  let result;
  switch (method) {
    case "initialize":
      result = { protocolVersion: "2026-07-28", capabilities: { tools: { listChanged: false } }, serverInfo: { name: "sandbox-router", version: "1.0.0" } };
      break;
    case "notifications/initialized": return { jsonrpc: "2.0", id, result: {} };
    case "tools/list": result = { tools: MCP_TOOLS }; break;
    case "tools/call":
      try { result = await callMcpTool(params.name, params.arguments || {}, env); }
      catch (err) { result = { isError: true, content: [{ type: "text", text: `Error: ${err.message}` }] }; }
      break;
    case "ping": result = {}; break;
    default: return { jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } };
  }
  return { jsonrpc: "2.0", id, result };
}

// ─── Main Worker ──────────────────────────────────────────────────────────────

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/mcp") {
      return handleMcp(request, env);
    }

    if (url.pathname === "/health") {
      return new Response(JSON.stringify({ status: "ok" }), { headers: { "Content-Type": "application/json" } });
    }

    if (url.pathname === "/" && request.method === "POST") {
      const contentType = request.headers.get("Content-Type") || "";
      const maxIterations = parseInt(env.MAX_ITERATIONS || "10", 10);
      let userPrompt, sessionId, uploadedFiles;

      if (contentType.includes("multipart/form-data")) {
        sessionId = url.searchParams.get("sessionId") || "default";
        const sandboxId = `${env.SANDBOX_ID_PREFIX || "llm-session"}-${sessionId}`;
        await setupSandboxEnv(env, sandboxId);
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

      const sandboxId = `${env.SANDBOX_ID_PREFIX || "llm-session"}-${sessionId}`;
      await setupSandboxEnv(env, sandboxId);

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

      return new Response(JSON.stringify({ sessionId, sandboxId, model: env.LLM_MODEL || "@cf/meta/llama-3.3-70b-instruct-fp8-fast", uploadedFiles, iterations: messages.filter((m) => m.role === "assistant").length, finalResponse: messages[messages.length - 1]?.content, executionLog }, null, 2), { headers: { "Content-Type": "application/json" } });
    }

    if (url.pathname === "/file" && request.method === "GET") {
      const sessionId = url.searchParams.get("session") || "default";
      const filePath = url.searchParams.get("path");
      if (!filePath) { return new Response(JSON.stringify({ error: "Missing 'path' parameter" }), { status: 400, headers: { "Content-Type": "application/json" } }); }
      const sandboxId = `${env.SANDBOX_ID_PREFIX || "llm-session"}-${sessionId}`;
      const output = await execInSandbox(env, sandboxId, `cat '${filePath}'`);
      return new Response(output, { headers: { "Content-Type": "text/plain" } });
    }

    if (url.pathname === "/favicon.ico") { return new Response(null, { status: 404 }); }

    return new Response(JSON.stringify({ name: "sandbox-router", endpoints: { "POST /": "Sandbox mode (shell execution + file upload)", "GET /file": "Download file from sandbox", "GET /health": "Health check", "POST /mcp": "MCP server (Streamable HTTP)" }, status: "ok" }), { headers: { "content-type": "application/json" } });
  },
};
