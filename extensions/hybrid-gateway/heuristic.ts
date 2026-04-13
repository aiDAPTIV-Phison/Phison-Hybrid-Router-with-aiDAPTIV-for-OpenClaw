import type { ClassifyResult, ComplexityLevel, Skill } from "./types.js";

// Keyword groups that boost complexity and add skills
const KEYWORD_RULES: Array<{
  patterns: RegExp;
  addSkill: Skill;
  minComplexity: ComplexityLevel;
}> = [
  {
    patterns:
      /\b(code|function|class|import|export|def|const|let|var|async|await|return)\b/i,
    addSkill: "coding",
    minComplexity: "moderate",
  },
  {
    patterns:
      /\b(debug|error|bug|fix|crash|exception|traceback|stack\s*trace)\b/i,
    addSkill: "coding",
    minComplexity: "complex",
  },
  {
    patterns:
      /\b(architect|design|system|scale|infrastructure|microservice|distributed)\b/i,
    addSkill: "analysis",
    minComplexity: "complex",
  },
  {
    patterns: /\b(translate|翻譯|翻译)\b/i,
    addSkill: "translation",
    minComplexity: "simple",
  },
  {
    patterns: /\b(搜尋|搜索|search|lookup|find\s+info)\b/i,
    addSkill: "search",
    minComplexity: "simple",
  },
];

const COMPLEXITY_ORDER: ComplexityLevel[] = [
  "trivial",
  "simple",
  "moderate",
  "complex",
  "expert",
];

function maxComplexity(a: ComplexityLevel, b: ComplexityLevel): ComplexityLevel {
  const ai = COMPLEXITY_ORDER.indexOf(a);
  const bi = COMPLEXITY_ORDER.indexOf(b);
  return ai >= bi ? a : b;
}

function lengthBasedComplexity(text: string): ComplexityLevel {
  const len = text.length;
  if (len < 20) return "trivial";
  if (len < 100) return "simple";
  if (len < 500) return "moderate";
  return "complex";
}

/**
 * Pure rule-based classification as fallback when the model
 * returns invalid JSON or times out.
 */
export function heuristicClassify(input: string): ClassifyResult {
  let complexity = lengthBasedComplexity(input);
  const skills = new Set<Skill>();

  for (const rule of KEYWORD_RULES) {
    if (rule.patterns.test(input)) {
      skills.add(rule.addSkill);
      complexity = maxComplexity(complexity, rule.minComplexity);
    }
  }

  if (skills.size === 0) {
    skills.add("conversation");
  }

  return {
    complexity,
    skills: [...skills],
  };
}
