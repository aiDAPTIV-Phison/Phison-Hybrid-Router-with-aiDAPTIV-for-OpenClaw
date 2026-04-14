// Complexity levels ordered by severity (index = numeric value)
export const COMPLEXITY_LEVELS = [
  "trivial",
  "simple",
  "moderate",
  "complex",
  "expert",
] as const;

export type ComplexityLevel = (typeof COMPLEXITY_LEVELS)[number];

export type Skill =
  | "coding"
  | "math"
  | "creative"
  | "analysis"
  | "translation"
  | "search"
  | "tool-use"
  | "image-gen"
  | "conversation"
  | "summarization"
  | "reasoning";

export type Tier = "gateway" | "edge" | "cloud";

export type RoutingPolicy =
  | "edge-first"
  | "cloud-first"
  | "cost-optimize"
  | "quality-first"
  | "cost-optimize-L1"
  | "cost-optimize-L2"
  | "cost-optimize-L3";

// --- Classifier output ---

export type ClassifyResult = {
  complexity: ComplexityLevel;
  skills: Skill[];
};

// --- Router output ---

export type RoutingDecision = {
  provider: string;
  model: string;
  tier: Tier;
  reason: string;
};

// --- Skill route rule ---

export type SkillRoute = {
  skillPattern: string;
  forceTier?: Tier;
  preferModel?: string;
  reason?: string;
};

// --- Model mapping per tier ---

export type TierModelMapping = {
  provider: string;
  model: string;
};

// --- Plugin config (matches openclaw plugin config section) ---

export type ThinkingStrategy = "auto" | "gemma4-raw" | "qwen-nothink";

export type HybridGatewayConfig = {
  classifier: {
    mode: "model" | "heuristic";
    baseUrl: string;
    apiKey: string;
    model: string;
    maxLatencyMs: number;
    cacheEnabled: boolean;
    cacheTtlSeconds: number;
    /** Override the built-in classifier system prompt. */
    systemPrompt?: string;
    /** Suppress model thinking during classification to reduce latency. */
    disableThinking?: boolean;
    /**
     * How to suppress thinking:
     * - "auto": inject /nothink in system prompt (universal) + use raw completions for Gemma 4
     * - "gemma4-raw": raw /v1/completions with no-thinking prompt template
     * - "qwen-nothink": inject /nothink in system prompt (Qwen 3/3.5)
     */
    thinkingStrategy?: ThinkingStrategy;
  };
  routing: {
    policy: RoutingPolicy;
    skillRoutes: SkillRoute[];
    fallbackEnabled: boolean;
    /** Regex patterns (case-insensitive). Prompts matching any pattern bypass routing override. */
    bypassPatterns?: string[];
  };
  models: {
    gateway: TierModelMapping;
    edge: TierModelMapping;
    cloud: TierModelMapping;
  };
};
