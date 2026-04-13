// Post-install helper: configure the hybrid-gateway cloud provider.
// Two modes:
//   Interactive:     node configure-cloud.cjs
//   Non-interactive: node configure-cloud.cjs <providerId> <baseUrl> <api> <apiKey> <model>

"use strict";
const fs = require("fs");
const path = require("path");
const readline = require("readline");

const PROVIDERS = [
  {
    id: "openrouter",
    name: "OpenRouter",
    baseUrl: "https://openrouter.ai/api/v1",
    api: "openai-completions",
    defaultModel: "google/gemini-2.5-flash",
    envHint: "OPENROUTER_API_KEY",
  },
  {
    id: "google",
    name: "Google Gemini",
    baseUrl: "https://generativelanguage.googleapis.com/v1beta",
    api: "google-generative-ai",
    defaultModel: "gemini-2.5-flash",
    envHint: "GOOGLE_API_KEY",
  },
  {
    id: "anthropic",
    name: "Anthropic (Claude)",
    baseUrl: "https://api.anthropic.com",
    api: "anthropic-messages",
    defaultModel: "claude-sonnet-4-20250514",
    envHint: "ANTHROPIC_API_KEY",
  },
  {
    id: "openai",
    name: "OpenAI",
    baseUrl: "https://api.openai.com/v1",
    api: "openai-completions",
    defaultModel: "gpt-4o",
    envHint: "OPENAI_API_KEY",
  },
  {
    id: "together",
    name: "Together AI",
    baseUrl: "https://api.together.xyz/v1",
    api: "openai-completions",
    defaultModel: "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8",
    envHint: "TOGETHER_API_KEY",
  },
];

const configPath = path.join(
  process.env.USERPROFILE || process.env.HOME || "",
  ".openclaw",
  "openclaw.json",
);

function readConfig() {
  try {
    return JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch (e) {
    throw new Error("Could not read " + configPath + ": " + e.message);
  }
}

function writeConfig(cfg) {
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2), "utf8");
}

function updateConfig(providerId, baseUrl, api, apiKey, model) {
  const cfg = readConfig();

  if (!cfg.models) cfg.models = {};
  if (!cfg.models.providers) cfg.models.providers = {};

  const existing = cfg.models.providers[providerId] || {};
  cfg.models.providers[providerId] = {
    ...existing,
    baseUrl: baseUrl,
    apiKey: apiKey,
    api: api,
    models: existing.models || [],
  };

  if (
    cfg.plugins &&
    cfg.plugins.entries &&
    cfg.plugins.entries["hybrid-gateway"] &&
    cfg.plugins.entries["hybrid-gateway"].config &&
    cfg.plugins.entries["hybrid-gateway"].config.models
  ) {
    cfg.plugins.entries["hybrid-gateway"].config.models.cloud = {
      provider: providerId,
      model: model,
    };
  }

  writeConfig(cfg);
  return cfg;
}

// --- Non-interactive mode: args passed from Inno Setup GUI ---
if (process.argv.length >= 7) {
  const [, , providerId, baseUrl, api, apiKey, model] = process.argv;
  try {
    updateConfig(providerId, baseUrl, api, apiKey, model);
    console.log("Cloud provider configured: " + providerId + " / " + model);
    process.exit(0);
  } catch (e) {
    console.error("Error: " + e.message);
    process.exit(1);
  }
}

// --- Interactive mode: run from console directly ---
function ask(rl, question) {
  return new Promise((resolve) => rl.question(question, resolve));
}

function waitForEnter(msg) {
  return new Promise((resolve) => {
    const rl2 = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl2.question(msg, () => { rl2.close(); resolve(); });
  });
}

async function main() {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  console.log("");
  console.log("  ===================================================");
  console.log("  aiDAPTIVClaw - Cloud Model Provider Configuration");
  console.log("  ===================================================");
  console.log("");
  console.log("  The hybrid-gateway cloud tier needs a cloud model");
  console.log("  provider. Select one and enter your API key.");
  console.log("");

  for (let i = 0; i < PROVIDERS.length; i++) {
    const p = PROVIDERS[i];
    console.log("  " + (i + 1) + ") " + p.name + "  (default model: " + p.defaultModel + ")");
  }
  console.log("  0) Skip (configure later via Control UI)");
  console.log("");

  const choice = await ask(rl, "  Select provider [0-" + PROVIDERS.length + "]: ");
  const idx = parseInt(choice, 10);

  if (!idx || idx < 1 || idx > PROVIDERS.length) {
    console.log("");
    console.log("  Skipped. You can configure the cloud provider later.");
    rl.close();
    return;
  }

  const provider = PROVIDERS[idx - 1];
  console.log("");
  console.log("  Selected: " + provider.name);
  console.log("  Env var hint: " + provider.envHint);
  console.log("");

  const apiKey = (await ask(rl, "  API Key: ")).trim();

  if (!apiKey) {
    console.log("");
    console.log("  No API key entered. Skipped.");
    rl.close();
    return;
  }

  const modelAnswer = (
    await ask(rl, "  Model [" + provider.defaultModel + "]: ")
  ).trim();
  const model = modelAnswer || provider.defaultModel;

  rl.close();

  updateConfig(provider.id, provider.baseUrl, provider.api, apiKey, model);

  console.log("");
  console.log("  Cloud provider configured:");
  console.log("    Provider : " + provider.name + " (" + provider.id + ")");
  console.log("    Model    : " + model);
  console.log("    Config   : " + configPath);
  console.log("");
}

main()
  .then(() => waitForEnter("  Press Enter to close this window..."))
  .catch(async (err) => {
    console.error("  Error: " + err.message);
    try { await waitForEnter("  Press Enter to close this window..."); } catch {}
    process.exit(1);
  });
