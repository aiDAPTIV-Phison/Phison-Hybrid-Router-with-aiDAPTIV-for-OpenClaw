import { COMPLEXITY_LEVELS, type ComplexityLevel } from "./types.js";

export const CLASSIFIER_SYSTEM_PROMPT = `You are a complexity classifier. Analyze the user message and return ONLY a JSON object. Input may be in any language.

COMPLEXITY LEVELS:
- "trivial": greetings, yes/no, pure arithmetic (e.g. "hi", "1+1")
- "simple": factual Q&A from memory, short translation, recalling known facts (NO file access needed)
- "moderate": single-topic tasks — write code, create basic files and directories, read/answer from one file, summarize one document, draft an email or blog, edit one config file, save notes to a file, web search + write-up
- "complex": multi-source or high-judgment tasks — process or read MANY input files/documents, batch edits across multiple existing files, data analysis from CSV/Excel/spreadsheets, triage or classify many input documents, deep competitive-research reports
- "expert": tasks requiring cloud resources — process PDFs or very large documents, generate images or media, novel algorithm design, PhD-level analysis

ESCALATION RULES (always apply — override the base level):
• Reading or processing a FOLDER of files, "all files in", or many documents at once → at least "complex"
• CSV, Excel, or spreadsheet data analysis → at least "complex"
• Creating a library/package with __init__.py, pyproject.toml, or test suites → at least "complex"
• Reading or analyzing a .pdf file → "expert"
• Generating or creating an image → "expert"

SKILLS (pick all that apply):
- coding: writing PROGRAM CODE (functions, classes, scripts with logic)
- math: calculations or proofs
- creative: creative writing, rewriting, brainstorming, blog posts
- analysis: data analysis, comparison, evaluation, report writing
- translation: language translation
- search: web search for real-time or external information
- tool-use: calling external APIs or executing tools
- image-gen: generating images or visual content
- conversation: simple chat, greetings
- summarization: condensing or summarizing documents
- reasoning: complex multi-step logic

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
