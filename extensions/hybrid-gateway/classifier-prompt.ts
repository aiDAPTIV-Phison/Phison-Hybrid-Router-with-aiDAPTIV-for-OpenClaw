import { COMPLEXITY_LEVELS, type ComplexityLevel } from "./types.js";

export const CLASSIFIER_SYSTEM_PROMPT = `You are a complexity classifier. Analyze the user message and return ONLY a JSON object. Input may be in any language.

COMPLEXITY — pick the LOWEST level that fits:
- "trivial": greetings (hi, hello, hey), single-word responses, yes/no questions, simple time queries, pure arithmetic with no context (e.g. "1+1", "2*3", "what is 5+7")
- "simple": basic factual Q&A, short translation, single lookup, simple file read, straightforward how-to with one step
- "moderate": multi-step tasks, short code snippets, summarization, short creative writing, simple file creation, config editing, basic data analysis, saving notes/memory to files
- "complex": system architecture design, multi-document deep synthesis, competitive research reports requiring expert judgment, comprehensive multi-dimensional comparison/analysis with structured output (tables + formatted code/HTML), tasks combining 3+ skills or requiring long-form content generation
- "expert": novel algorithm design, PhD-level proofs, cutting-edge research


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

export const NO_THINKING_SUFFIX = `\n/nothink\nDo not use any internal thinking or chain-of-thought. Respond with ONLY the JSON output.`;

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
