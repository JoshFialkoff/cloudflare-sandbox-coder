#!/usr/bin/env python3
import sys

path = "/Users/dev/cloudflare/sandbox-router/src/index.js"
with open(path, "r") as f:
    js = f.read()

changes = []

# 1. PREFERRED_COMPLEX_MODELS
old = '''var PREFERRED_COMPLEX_MODELS = [
  "@cf/openai/gpt-oss-120b",
  "@cf/moonshotai/kimi-k2.7-code",
  "@cf/zai-org/glm-5.3",
  "@cf/deepseek-ai/deepseek-r1-distill-qwen-32b"
];'''
new = '''var PREFERRED_COMPLEX_MODELS = [
  "@cf/openai/gpt-oss-120b",
  "@cf/moonshotai/kimi-k2.7-code",
  "@cf/zai-org/glm-5.3",
  "@cf/deepseek-ai/deepseek-v4-pro-0813",
  "@cf/deepseek-ai/deepseek-r1-distill-qwen-32b",
  "@cf/nvidia/nemotron-3-120b-a12b",
  "@cf/qwen/qwq-32b"
];'''
if old in js:
    js = js.replace(old, new); changes.append("PREFERRED_COMPLEX_MODELS: +qwq-32b, +deepseek-v4-pro, +nemotron-120b")
else:
    print("WARNING: PREFERRED_COMPLEX_MODELS not found")

# 2. PREFERRED_CODING_MODELS
old = '''var PREFERRED_CODING_MODELS = [
  "@cf/moonshotai/kimi-k2.7-code",
  "@cf/openai/gpt-oss-120b",
  "@cf/zai-org/glm-5.3",
  "@cf/deepseek-ai/deepseek-v4-flash-0731",
  "@cf/zai-org/glm-5.3-flash",
  "@cf/deepseek-ai/deepseek-r1-distill-qwen-32b"
];'''
new = '''var PREFERRED_CODING_MODELS = [
  "@cf/moonshotai/kimi-k2.7-code",
  "@cf/openai/gpt-oss-120b",
  "@cf/zai-org/glm-5.3",
  "@cf/deepseek-ai/deepseek-v4-flash-0731",
  "@cf/zai-org/glm-5.3-flash",
  "@cf/deepseek-ai/deepseek-r1-distill-qwen-32b",
  "@cf/qwen/qwen2.5-coder-32b-instruct"
];'''
if old in js:
    js = js.replace(old, new); changes.append("PREFERRED_CODING_MODELS: +qwen2.5-coder-32b")
else:
    print("WARNING: PREFERRED_CODING_MODELS not found")

# 3. PREFERRED_GENERAL_MODELS
old = '''var PREFERRED_GENERAL_MODELS = [
  "@cf/openai/gpt-oss-120b",
  "@cf/moonshotai/kimi-k2.6",
  "@cf/zai-org/glm-5.3-flash",
  "@cf/zai-org/glm-4.7-flash"
];'''
new = '''var PREFERRED_GENERAL_MODELS = [
  "@cf/openai/gpt-oss-120b",
  "@cf/moonshotai/kimi-k2.6",
  "@cf/zai-org/glm-5.3-flash",
  "@cf/deepseek-ai/deepseek-v4.1-flash-1017",
  "@cf/zai-org/glm-4.7-flash"
];'''
if old in js:
    js = js.replace(old, new); changes.append("PREFERRED_GENERAL_MODELS: +deepseek-v4.1-flash")
else:
    print("WARNING: PREFERRED_GENERAL_MODELS not found")

# 4. PREFERRED_TOOL_MODELS
old = '''var PREFERRED_TOOL_MODELS = [
  "@cf/moonshotai/kimi-k2.6",
  "@cf/openai/gpt-oss-120b",
  "@cf/zai-org/glm-5.3"
];'''
new = '''var PREFERRED_TOOL_MODELS = [
  "@cf/moonshotai/kimi-k2.6",
  "@cf/openai/gpt-oss-120b",
  "@cf/zai-org/glm-5.3",
  "@cf/deepseek-ai/deepseek-v4-pro-0813"
];'''
if old in js:
    js = js.replace(old, new); changes.append("PREFERRED_TOOL_MODELS: +deepseek-v4-pro")
else:
    print("WARNING: PREFERRED_TOOL_MODELS not found")

# 5. COMPLEX_MODELS_FALLBACK
old = '''var COMPLEX_MODELS_FALLBACK = [
  "@cf/openai/gpt-oss-120b",
  "@cf/moonshotai/kimi-k2.7-code",
  "@cf/zai-org/glm-5.3",
  "@cf/deepseek-ai/deepseek-r1-distill-qwen-32b"
];'''
new = '''var COMPLEX_MODELS_FALLBACK = [
  "@cf/openai/gpt-oss-120b",
  "@cf/moonshotai/kimi-k2.7-code",
  "@cf/zai-org/glm-5.3",
  "@cf/deepseek-ai/deepseek-v4-pro-0813",
  "@cf/deepseek-ai/deepseek-r1-distill-qwen-32b",
  "@cf/nvidia/nemotron-3-120b-a12b",
  "@cf/qwen/qwq-32b"
];'''
if old in js:
    js = js.replace(old, new); changes.append("COMPLEX_MODELS_FALLBACK: matched PREFERRED")
else:
    print("WARNING: COMPLEX_MODELS_FALLBACK not found")

# 6. CODING_MODELS_FALLBACK
old = '''var CODING_MODELS_FALLBACK = [
  "@cf/moonshotai/kimi-k2.7-code",
  "@cf/openai/gpt-oss-120b",
  "@cf/deepseek-ai/deepseek-v4-flash-0731"
];'''
new = '''var CODING_MODELS_FALLBACK = [
  "@cf/moonshotai/kimi-k2.7-code",
  "@cf/openai/gpt-oss-120b",
  "@cf/deepseek-ai/deepseek-v4-flash-0731",
  "@cf/qwen/qwen2.5-coder-32b-instruct"
];'''
if old in js:
    js = js.replace(old, new); changes.append("CODING_MODELS_FALLBACK: +qwen2.5-coder-32b")
else:
    print("WARNING: CODING_MODELS_FALLBACK not found")

# 7. GENERAL_MODELS_FALLBACK
old = '''var GENERAL_MODELS_FALLBACK = [
  "@cf/openai/gpt-oss-120b",
  "@cf/moonshotai/kimi-k2.6",
  "@cf/zai-org/glm-4.7-flash"
];'''
new = '''var GENERAL_MODELS_FALLBACK = [
  "@cf/openai/gpt-oss-120b",
  "@cf/moonshotai/kimi-k2.6",
  "@cf/zai-org/glm-5.3-flash",
  "@cf/deepseek-ai/deepseek-v4.1-flash-1017",
  "@cf/zai-org/glm-4.7-flash"
];'''
if old in js:
    js = js.replace(old, new); changes.append("GENERAL_MODELS_FALLBACK: +glm-5.3-flash, +deepseek-v4.1-flash")
else:
    print("WARNING: GENERAL_MODELS_FALLBACK not found")

# 8. TOOL_MODELS_FALLBACK
old = '''var TOOL_MODELS_FALLBACK = [
  "@cf/moonshotai/kimi-k2.6",
  "@cf/openai/gpt-oss-120b"
];'''
new = '''var TOOL_MODELS_FALLBACK = [
  "@cf/moonshotai/kimi-k2.6",
  "@cf/openai/gpt-oss-120b",
  "@cf/deepseek-ai/deepseek-v4-pro-0813"
];'''
if old in js:
    js = js.replace(old, new); changes.append("TOOL_MODELS_FALLBACK: +deepseek-v4-pro")
else:
    print("WARNING: TOOL_MODELS_FALLBACK not found")

# 9. classifyPrompt threshold
old = 'const baseTier = researchScore >= 2 ? "complex" : isCoding ? "coding" : "general";'
new = 'const baseTier = researchScore >= 1 ? "complex" : isCoding ? "coding" : "general";'
if old in js:
    js = js.replace(old, new); changes.append("classifyPrompt: researchScore threshold 2 -> 1")
else:
    print("WARNING: classifyPrompt threshold not found")

with open(path, "w") as f:
    f.write(js)

print(f"\nApplied {len(changes)} changes:")
for c in changes:
    print(f"  - {c}")
print(f"\nFile saved: {path}")
print("Next: npx wrangler deploy")
