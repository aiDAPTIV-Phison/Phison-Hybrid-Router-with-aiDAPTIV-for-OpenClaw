import OpenAI from "openai";
import { CLASSIFIER_SYSTEM_PROMPT, NO_THINKING_SUFFIX, getComplexityValue } from "./classifier-prompt.js";
import { heuristicClassify } from "./heuristic.js";
import { COMPLEXITY_LEVELS, type ClassifyResult, type ComplexityLevel, type Skill, type ThinkingStrategy } from "./types.js";

// ---- Post-classification rules ----

const SKILL_COUNT_COMPLEXITY_FLOOR: { minSkills: number; floor: ComplexityLevel } = {
  minSkills: 4,
  floor: "complex",
};

function applyPostRules(result: ClassifyResult): ClassifyResult {
  const rule = SKILL_COUNT_COMPLEXITY_FLOOR;
  if (
    result.skills.length >= rule.minSkills &&
    getComplexityValue(result.complexity) < getComplexityValue(rule.floor)
  ) {
    return { ...result, complexity: rule.floor };
  }
  return result;
}

// ---- Cache ----

type CacheEntry = { result: ClassifyResult; expiresAt: number };

function createCache() {
  const store = new Map<string, CacheEntry>();

  function get(key: string): ClassifyResult | null {
    const entry = store.get(key);
    if (!entry) return null;
    if (Date.now() > entry.expiresAt) {
      store.delete(key);
      return null;
    }
    return entry.result;
  }

  function set(key: string, result: ClassifyResult, ttlSeconds: number) {
    store.set(key, { result, expiresAt: Date.now() + ttlSeconds * 1000 });
  }

  return { get, set };
}

// ---- JSON parsing ----

const VALID_SKILLS = new Set<string>([
  "coding", "math", "creative", "analysis", "translation",
  "search", "tool-use", "image-gen", "conversation", "summarization", "reasoning",
]);

function parseClassifyJson(raw: string): ClassifyResult | null {
  try {
    const jsonMatch = raw.match(/\{[\s\S]*\}/);
    if (!jsonMatch) return null;

    const obj = JSON.parse(jsonMatch[0]);

    const complexity: ComplexityLevel =
      COMPLEXITY_LEVELS.includes(obj.complexity) ? obj.complexity : "moderate";

    const skills: Skill[] = Array.isArray(obj.skills)
      ? obj.skills.filter((s: unknown) => typeof s === "string" && VALID_SKILLS.has(s as string))
      : [];

    if (skills.length === 0) skills.push("conversation");

    return { complexity, skills };
  } catch {
    return null;
  }
}

// ---- No-thinking prompt builders ----

/**
 * Gemma 4 26B/31B raw prompt without <|think|>.
 * The empty thought channel suppresses "ghost" thinking.
 */
function buildGemma4NoThinkPrompt(systemContent: string, userContent: string): string {
  return (
    `<|turn>system\n${systemContent}<turn|>\n` +
    `<|turn>user\n${userContent}<turn|>\n` +
    `<|turn>model\n` +
    `<|channel>thought\n<channel|>`
  );
}

function isGemma4Model(model: string): boolean {
  return /gemma[-_]?4/i.test(model);
}

function resolveStrategy(model: string, strategy?: ThinkingStrategy): ThinkingStrategy {
  if (strategy && strategy !== "auto") return strategy;
  return isGemma4Model(model) ? "gemma4-raw" : "qwen-nothink";
}

// ---- Classifier ----

export type ClassifierOptions = {
  mode: "model" | "heuristic";
  baseUrl: string;
  apiKey: string;
  model: string;
  maxLatencyMs: number;
  cacheEnabled: boolean;
  cacheTtlSeconds: number;
  disableThinking?: boolean;
  thinkingStrategy?: ThinkingStrategy;
  logger?: { info: (msg: string) => void; warn: (msg: string) => void };
};

export function createClassifier(opts: ClassifierOptions) {
  const cache = createCache();
  const log = opts.logger ?? { info: () => {}, warn: () => {} };

  const client = new OpenAI({
    baseURL: opts.baseUrl,
    apiKey: opts.apiKey,
  });

  async function classify(input: string): Promise<ClassifyResult> {
    if (opts.mode === "heuristic") {
      return heuristicClassify(input);
    }

    // L1: Cache
    if (opts.cacheEnabled) {
      const cached = cache.get(input);
      if (cached) {
        log.info(`[hybrid-gw] cache hit for classify`);
        return cached;
      }
    }

    // L2: Model classification
    const inputPreview = input.length > 200 ? input.slice(0, 200) + "..." : input;
    log.info(`[hybrid-gw] classifier input (${input.length} chars): ${inputPreview}`);
    try {
      const controller = new AbortController();
      const timeout = setTimeout(
        () => controller.abort(),
        opts.maxLatencyMs,
      );

      let content: string;

      if (opts.disableThinking) {
        const strategy = resolveStrategy(opts.model, opts.thinkingStrategy);
        log.info(`[hybrid-gw] thinking disabled, strategy=${strategy}`);

        if (strategy === "gemma4-raw") {
          // Raw completions — bypasses chat template so no <|think|> is injected
          const systemWithNothink = CLASSIFIER_SYSTEM_PROMPT + NO_THINKING_SUFFIX;
          const rawPrompt = buildGemma4NoThinkPrompt(systemWithNothink, input);
          const response = await client.completions.create(
            {
              model: opts.model,
              prompt: rawPrompt,
              max_tokens: 200,
              temperature: 0,
              stop: ["<turn|>", "<|turn>"],
            },
            { signal: controller.signal },
          );
          content = response.choices?.[0]?.text ?? "";
        } else {
          // qwen-nothink (and general fallback): /nothink in system prompt
          const systemWithNothink = CLASSIFIER_SYSTEM_PROMPT + NO_THINKING_SUFFIX;
          // llama.cpp /v1/chat/completions: jinja template kwarg for Qwen3-style models
          // (ignored by strict OpenAI; safe for local OpenAI-compatible stacks).
          const chatBody: OpenAI.Chat.ChatCompletionCreateParams & {
            chat_template_kwargs?: { enable_thinking?: boolean };
          } = {
            model: opts.model,
            messages: [
              { role: "system", content: systemWithNothink },
              { role: "user", content: input },
            ],
            max_tokens: 200,
            temperature: 0,
            chat_template_kwargs: { enable_thinking: false },
          };
          const response = await client.chat.completions.create(chatBody, {
            signal: controller.signal,
          });
          content = response.choices?.[0]?.message?.content ?? "";
        }
      } else {
        // Standard chat completions — server chat template controls thinking
        const response = await client.chat.completions.create(
          {
            model: opts.model,
            messages: [
              { role: "system", content: CLASSIFIER_SYSTEM_PROMPT },
              { role: "user", content: input },
            ],
            max_tokens: 200,
            temperature: 0,
          },
          { signal: controller.signal },
        );
        content = response.choices?.[0]?.message?.content ?? "";
      }

      clearTimeout(timeout);

      log.info(`[hybrid-gw] classifier raw response: ${content}`);

      const parsed = parseClassifyJson(content);

      if (parsed) {
        const final = applyPostRules(parsed);
        if (final.complexity !== parsed.complexity) {
          log.info(
            `[hybrid-gw] post-rule: ${parsed.complexity} -> ${final.complexity} (${parsed.skills.length} skills >= ${SKILL_COUNT_COMPLEXITY_FLOOR.minSkills})`,
          );
        }
        if (opts.cacheEnabled) {
          cache.set(input, final, opts.cacheTtlSeconds);
        }
        log.info(
          `[hybrid-gw] classified: complexity=${final.complexity} skills=[${final.skills}]`,
        );
        return final;
      }

      log.warn(`[hybrid-gw] model returned unparseable JSON, falling back to heuristic`);
    } catch (err) {
      log.warn(
        `[hybrid-gw] classifier model call failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    }

    // L3: Heuristic fallback
    const fallback = applyPostRules(heuristicClassify(input));
    log.info(`[hybrid-gw] heuristic fallback: complexity=${fallback.complexity}`);
    return fallback;
  }

  return { classify };
}
