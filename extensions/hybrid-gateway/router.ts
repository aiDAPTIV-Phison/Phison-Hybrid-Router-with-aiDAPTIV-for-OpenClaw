import { getComplexityValue } from "./classifier-prompt.js";
import type {
  ClassifyResult,
  ComplexityLevel,
  HybridGatewayConfig,
  RoutingDecision,
  RoutingPolicy,
  SkillRoute,
  Tier,
  TierModelMapping,
} from "./types.js";

// ---- Policy Array Override (takes precedence over `policy` when present) ----

function applyPolicyArray(
  complexity: ComplexityLevel,
  policyArray: Tier[],
): Tier {
  const idx = getComplexityValue(complexity);
  const tier = policyArray[idx];
  return tier ?? "edge";
}

// ---- Skill Route Override (Stage 1) ----

function matchSkillRoute(
  skills: string[],
  routes: SkillRoute[],
): SkillRoute | null {
  for (const route of routes) {
    const regex = new RegExp(route.skillPattern, "i");
    for (const skill of skills) {
      if (regex.test(skill)) return route;
    }
  }
  return null;
}

// ---- Routing Policy (Stage 2) ----

/**
 * Routing policy table.
 *
 * | complexity      | edge-first | cloud-first | cost-optimize-L1 | cost-optimize-L2 | cost-optimize-L3 |
 * |-----------------|------------|-------------|------------------|------------------|------------------|
 * | trivial   (0)   | edge       | cloud       | edge             | classifier          | classifier          |
 * | simple    (1)   | edge       | cloud       | edge             | classifier          | classifier          |
 * | moderate  (2)   | edge       | cloud       | cloud            | edge             | edge             |
 * | complex   (3)   | edge       | cloud       | cloud            | cloud            | edge             |
 * | expert    (4)   | edge       | cloud       | cloud            | cloud            | cloud            |
 *
 * L1 (small  ~3B):     0-1 -> edge(=classifier), 2-4 -> cloud
 * L2 (medium ~26-35B): 0-1 -> classifier, 2 -> edge, 3-4 -> cloud
 * L3 (large  ~120B):   0-1 -> classifier, 2-3 -> edge, 4 -> cloud
 */
function applyPolicy(
  complexity: ComplexityLevel,
  policy: RoutingPolicy,
): Tier {
  if (policy === "edge-first") return "edge";
  if (policy === "cloud-first") return "cloud";

  const val = getComplexityValue(complexity);

  if (policy === "cost-optimize-L1") {
    return val <= 1 ? "edge" : "cloud";
  }
  if (policy === "cost-optimize-L2") {
    if (val <= 1) return "classifier";
    if (val === 2) return "edge";
    return "cloud";
  }
  if (policy === "cost-optimize-L3") {
    if (val <= 1) return "classifier";
    if (val <= 3) return "edge";
    return "cloud";
  }

  // Fallback for unrecognized policy: treat as L1
  return val <= 1 ? "edge" : "cloud";
}

// ---- Router ----

function resolveModelForTier(
  tier: Tier,
  models: { classifier: TierModelMapping; edge: TierModelMapping; cloud: TierModelMapping },
): TierModelMapping {
  return models[tier];
}

export function route(
  classifyResult: ClassifyResult,
  config: HybridGatewayConfig,
): RoutingDecision {
  const { routing, models } = config;

  // Stage 1: Skill Route Override
  const matched = matchSkillRoute(classifyResult.skills, routing.skillRoutes);
  if (matched) {
    if (matched.preferModel) {
      const tier: Tier = matched.forceTier ?? "cloud";
      const mapping = resolveModelForTier(tier, models);
      return {
        provider: mapping.provider,
        model: mapping.model,
        tier,
        reason: `skill-route: pattern=${matched.skillPattern}, skills=[${classifyResult.skills}], ${matched.reason ?? ""}`,
      };
    }
    if (matched.forceTier) {
      const mapping = resolveModelForTier(matched.forceTier, models);
      return {
        provider: mapping.provider,
        model: mapping.model,
        tier: matched.forceTier,
        reason: `skill-route: pattern=${matched.skillPattern}, forceTier=${matched.forceTier}, skills=[${classifyResult.skills}], ${matched.reason ?? ""}`,
      };
    }
  }

  // Stage 2a: Policy Array Override (takes precedence over `policy` when present and valid).
  if (routing.policyArray && routing.policyArray.length === 5) {
    const tier = applyPolicyArray(classifyResult.complexity, routing.policyArray);
    const mapping = resolveModelForTier(tier, models);
    return {
      provider: mapping.provider,
      model: mapping.model,
      tier,
      reason: `policy-array=[${routing.policyArray.join(",")}], complexity=${classifyResult.complexity}, skills=[${classifyResult.skills}] -> ${tier}`,
    };
  }

  // Stage 2b: Routing Policy (three-tier fixed mapping)
  const tier = applyPolicy(classifyResult.complexity, routing.policy);
  const mapping = resolveModelForTier(tier, models);

  return {
    provider: mapping.provider,
    model: mapping.model,
    tier,
    reason: `policy=${routing.policy}, complexity=${classifyResult.complexity}, skills=[${classifyResult.skills}] -> ${tier}`,
  };
}
