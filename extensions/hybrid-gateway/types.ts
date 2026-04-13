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
  | "quality-first";

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

export type HybridGatewayConfig = {
  classifier: {
    mode: "model" | "heuristic";
    baseUrl: string;
    apiKey: string;
    model: string;
    maxLatencyMs: number;
    cacheEnabled: boolean;
    cacheTtlSeconds: number;
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
