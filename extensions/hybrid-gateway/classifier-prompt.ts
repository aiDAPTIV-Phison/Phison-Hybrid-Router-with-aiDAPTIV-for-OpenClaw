import { COMPLEXITY_LEVELS, type ComplexityLevel } from "./types.js";

export const CLASSIFIER_SYSTEM_PROMPT = `You are a complexity classifier. Analyze the user message and return ONLY a JSON object. Input may be in any language.

COMPLEXITY — pick the LOWEST level that fits:
- "trivial": greetings (hi, hello, hey), single-word responses, yes/no questions, simple time queries, pure arithmetic with no context (e.g. "1+1", "2*3", "what is 5+7")
- "simple": basic factual Q&A, short translation, single lookup, simple file read, straightforward how-to with one step
- "moderate": multi-step tasks, writing code snippets, summarization, creative writing, file creation, config editing, data analysis, saving notes/memory to files
- "complex": system architecture design, multi-document deep synthesis, competitive research reports requiring expert judgment
- "expert": novel algorithm design, PhD-level proofs, cutting-edge research

When in doubt between two levels, pick the lower one. Reserve "complex" only for tasks needing deep expertise across multiple domains. Saving or storing information to files is always "moderate" at most.

SKILLS (pick all that apply):
- coding: writing or debugging PROGRAM CODE (functions, classes, scripts with logic). NOT file saving, NOT config editing, NOT writing markdown/text
- math: calculations or proofs
- creative: creative writing, stories, brainstorming, content rewriting, blog posts
- analysis: data analysis, comparison, evaluation, report writing
- translation: language translation
- search: requires web search for real-time or external information
- tool-use: requires calling external APIs or executing tools
- image-gen: generating or creating images, illustrations, diagrams, or visual content
- conversation: simple chat, greetings
- summarization: condensing or summarizing documents
- reasoning: complex logic, multi-step reasoning chains

OUTPUT FORMAT (JSON only, no markdown):
{"complexity":"<level>","skills":["<skill>"]}`;

const complexityValue = new Map<string, number>(
  COMPLEXITY_LEVELS.map((level, idx) => [level, idx]),
);

export function getComplexityValue(level: ComplexityLevel): number {
  return complexityValue.get(level) ?? 0;
}

export function isAtOrAboveThreshold(
  detected: ComplexityLevel,
  threshold: ComplexityLevel,
): boolean {
  return getComplexityValue(detected) >= getComplexityValue(threshold);
}
