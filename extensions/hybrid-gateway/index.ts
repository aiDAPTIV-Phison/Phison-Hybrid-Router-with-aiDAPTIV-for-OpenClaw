import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { createClassifier } from "./classifier.js";
import { route } from "./router.js";
import type { HybridGatewayConfig, Tier } from "./types.js";

// Minimal plugin API type (avoids importing from openclaw/plugin-sdk which
// fails when the plugin lives outside the OpenClaw package tree).
type PluginApi = {
  pluginConfig?: Record<string, unknown>;
  logger: { info: (msg: string) => void; warn: (msg: string) => void; error: (msg: string) => void; debug: (msg: string) => void };
  on: (hookName: string, handler: (event: { prompt: string }, ctx: unknown) => Promise<{ modelOverride?: string; providerOverride?: string } | void> | void) => void;
};

// ---- Global routing-decision store (read by gateway chat handler) ----

type StoredRoutingDecision = { tier: string; provider: string; model: string; reason: string; ts: number };
const LAST_DECISION_KEY = "__hybridGatewayLastDecision";

function setLastDecision(decision: StoredRoutingDecision) {
  (globalThis as Record<string, unknown>)[LAST_DECISION_KEY] = decision;
}

// ---- File Logger ----

const LOG_DIR = process.platform === "win32" ? "C:\\tmp\\openclaw" : "/tmp/openclaw";
const LOG_FILE = path.join(LOG_DIR, "hybrid-gateway.log");

function ensureLogDir() {
  try { fs.mkdirSync(LOG_DIR, { recursive: true }); } catch { /* ignore */ }
}

function fileLog(tier: string, provider: string, model: string, complexity: string, skills: string[], prompt: string) {
  const ts = new Date().toISOString();
  const promptPreview = prompt.length > 80 ? prompt.slice(0, 80) + "..." : prompt;
  const line = `${ts} | ${tier.padEnd(5)} | ${provider}/${model} | complexity=${complexity} skills=[${skills}] | "${promptPreview}"\n`;
  fsp.appendFile(LOG_FILE, line).catch(() => {});
}

// ---- Defaults ----

const DEFAULT_CONFIG: HybridGatewayConfig = {
  classifier: {
    mode: "model",
    baseUrl: "http://127.0.0.1:13142/v1",
    apiKey: "empty",
    model: "qwen2.5-3b-instruct-q4_k_m",
    maxLatencyMs: 30000,
    cacheEnabled: true,
    cacheTtlSeconds: 300,
  },
  routing: {
    policy: "cost-optimize-L2",
    skillRoutes: [],
    fallbackEnabled: true,
    newSessionTier: "cloud",
  },
  models: {
    gateway: { provider: "llamacpp", model: "qwen2.5-3b-instruct-q4_k_m" },
    edge: { provider: "llamacpp", model: "gpt-oss-120b-Q4_K_M" },
    cloud: { provider: "google", model: "gemini-2.5-flash" },
  },
};

function mergeConfig(
  userCfg: Record<string, unknown> | undefined,
): HybridGatewayConfig {
  if (!userCfg) return DEFAULT_CONFIG;

  const cls = (userCfg.classifier as Record<string, unknown>) ?? {};
  const rt = (userCfg.routing as Record<string, unknown>) ?? {};
  const mdl = (userCfg.models as Record<string, unknown>) ?? {};

  return {
    classifier: { ...DEFAULT_CONFIG.classifier, ...cls } as HybridGatewayConfig["classifier"],
    routing: { ...DEFAULT_CONFIG.routing, ...rt } as HybridGatewayConfig["routing"],
    models: {
      gateway: { ...DEFAULT_CONFIG.models.gateway, ...(mdl.gateway as Record<string, unknown> ?? {}) } as HybridGatewayConfig["models"]["gateway"],
      edge: { ...DEFAULT_CONFIG.models.edge, ...(mdl.edge as Record<string, unknown> ?? {}) } as HybridGatewayConfig["models"]["edge"],
      cloud: { ...DEFAULT_CONFIG.models.cloud, ...(mdl.cloud as Record<string, unknown> ?? {}) } as HybridGatewayConfig["models"]["cloud"],
    },
  };
}

// ---- User Text Extraction ----

/**
 * Strip OpenClaw sender metadata envelope and timestamp prefix from a raw
 * prompt so the classifier only sees the actual user text.
 *
 * Handles the following envelope format injected by OpenClaw:
 *
 *   Sender (untrusted metadata):
 *   ```json
 *   { "label": "...", "id": "..." }
 *   ```
 *
 *   [Wed 2026-04-08 12:25 GMT+8] <actual user text>
 */
export function extractUserText(prompt: string): string {
  let text = prompt;

  // Remove "Sender (untrusted metadata):" block (header + fenced JSON block)
  text = text.replace(/Sender \(untrusted metadata\):\s*```[\s\S]*?```\s*/g, "");

  // Remove leading timestamp prefix like "[Wed 2026-04-08 12:25 GMT+8] "
  text = text.replace(/^\[.*?\]\s*/gm, "");

  return text.trim();
}

// ---- Plugin Definition ----

const hybridGatewayPlugin = {
  id: "hybrid-gateway",
  name: "Hybrid Gateway",
  description:
    "Routes requests between local (edge) and cloud models based on complexity classification. Prioritizes local models for cost reduction.",

  register(api: PluginApi) {
    const config = mergeConfig(api.pluginConfig);
    const log = api.logger;

    ensureLogDir();

    // Validate newSessionTier is a known tier with a usable provider/model;
    // otherwise fall back to "cloud" so a typo in config never breaks startup.
    const VALID_TIERS: Tier[] = ["gateway", "edge", "cloud"];
    const FAILSAFE_TIER: Tier = "cloud";
    let newSessionTier: Tier = config.routing.newSessionTier ?? FAILSAFE_TIER;
    if (!VALID_TIERS.includes(newSessionTier)) {
      log.warn(
        `[hybrid-gw] invalid routing.newSessionTier="${newSessionTier}", falling back to "${FAILSAFE_TIER}"`,
      );
      newSessionTier = FAILSAFE_TIER;
    }
    if (
      !config.models[newSessionTier]?.provider ||
      !config.models[newSessionTier]?.model
    ) {
      log.warn(
        `[hybrid-gw] routing.newSessionTier="${newSessionTier}" has no provider/model configured, falling back to "${FAILSAFE_TIER}"`,
      );
      newSessionTier = FAILSAFE_TIER;
    }

    log.info(
      `[hybrid-gw] initializing: policy=${config.routing.policy}, ` +
      `classifier=${config.classifier.mode}, ` +
      `newSessionTier=${newSessionTier}, ` +
      `gateway=${config.models.gateway.provider}/${config.models.gateway.model}, ` +
      `edge=${config.models.edge.provider}/${config.models.edge.model}, ` +
      `cloud=${config.models.cloud.provider}/${config.models.cloud.model}`,
    );
    log.info(`[hybrid-gw] routing log -> ${LOG_FILE}`);

    const classifier = createClassifier({
      ...config.classifier,
      logger: log,
    });

    api.on("before_model_resolve", async (event, _ctx) => {
      const prompt = event.prompt;
      const t0 = performance.now();

      // /new or /reset startup → force the configured tier for this request
      if (prompt?.includes("A new session was started via /new or /reset")) {
        const target = config.models[newSessionTier];
        const reason = `force-${newSessionTier} (new session startup)`;
        log.info(`[hybrid-gw] ${reason} -> ${target.provider}/${target.model}`);
        setLastDecision({
          tier: newSessionTier,
          provider: target.provider,
          model: target.model,
          reason,
          ts: Date.now(),
        });
        return { providerOverride: target.provider, modelOverride: target.model };
      }

      if (!prompt?.trim()) return;
      
      const bypassPatterns = config.routing.bypassPatterns ?? [];
      for (const pattern of bypassPatterns) {
        if (new RegExp(pattern, "i").test(prompt)) {
          log.info(`[hybrid-gw] bypass: matched pattern "${pattern}", skipping routing`);
          return undefined;
        }
      }

      try {
        const t1 = performance.now();
        const classifyInput = extractUserText(prompt);
        const classifyResult = await classifier.classify(classifyInput);
        log.info(`[hybrid-gw] classify input (extracted): "${classifyInput.slice(0, 120)}${classifyInput.length > 120 ? "..." : ""}"`);
        const t2 = performance.now();
        const decision = route(classifyResult, config);
        const t3 = performance.now();

        log.info(
          `[hybrid-gw] route: ${decision.tier} -> ${decision.provider}/${decision.model} | ${decision.reason}`,
        );
        log.info(
          `[hybrid-gw] timing: classify=${(t2 - t1).toFixed(1)}ms route=${(t3 - t2).toFixed(1)}ms total=${(t3 - t0).toFixed(1)}ms`,
        );

        fileLog(
          decision.tier,
          decision.provider,
          decision.model,
          classifyResult.complexity,
          classifyResult.skills,
          prompt,
        );

        setLastDecision({
          tier: decision.tier,
          provider: decision.provider,
          model: decision.model,
          reason: decision.reason,
          ts: Date.now(),
        });

        return {
          providerOverride: decision.provider,
          modelOverride: decision.model,
        };
      } catch (err) {
        log.warn(
          `[hybrid-gw] routing failed, letting OpenClaw use default model: ${
            err instanceof Error ? err.message : String(err)
          }`,
        );
        return undefined;
      }
    });
  },
};

export default hybridGatewayPlugin;
