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
 * Three-tier routing (v3).
 *
 * | complexity      | edge-first | cloud-first | cost-optimize | quality-first |
 * |-----------------|------------|-------------|---------------|---------------|
 * | trivial   (0)   | edge       | cloud       | gateway       | gateway       |
 * | simple    (1)   | edge       | cloud       | gateway       | gateway       |
 * | moderate  (2)   | edge       | cloud       | edge          | edge          |
 * | complex   (3)   | edge       | cloud       | cloud         | cloud         |
 * | expert    (4)   | edge       | cloud       | cloud         | cloud         |
 */
function applyPolicy(
  complexity: ComplexityLevel,
  policy: RoutingPolicy,
): Tier {
  if (policy === "edge-first") return "edge";
  if (policy === "cloud-first") return "cloud";

  // cost-optimize / quality-first: 0-1 -> gateway, 2 -> edge, 3-4 -> cloud
  const val = getComplexityValue(complexity);
  if (val <= 1) return "gateway";
  if (val === 2) return "edge";
  return "cloud";
}

// ---- Router ----

function resolveModelForTier(
  tier: Tier,
  models: { gateway: TierModelMapping; edge: TierModelMapping; cloud: TierModelMapping },
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

  // Stage 2: Routing Policy (three-tier fixed mapping)
  const tier = applyPolicy(classifyResult.complexity, routing.policy);
  const mapping = resolveModelForTier(tier, models);

  return {
    provider: mapping.provider,
    model: mapping.model,
    tier,
    reason: `policy=${routing.policy}, complexity=${classifyResult.complexity}, skills=[${classifyResult.skills}] -> ${tier}`,
  };
}
