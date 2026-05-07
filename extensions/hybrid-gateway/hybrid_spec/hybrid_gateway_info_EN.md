# Hybrid Gateway — Routing Mechanism Documentation

---

## 1. Overall Flow

```
User Input
  │
  ▼
╔═══════════════════════════════════════════════════════════╗
║  Pre-check: New Session / Bypass                          ║
║  • /new or /reset → force newSessionTier (default cloud)  ║
║  • Bypass pattern matched → hand back to OpenClaw default ║
╠═══════════════════════════════════════════════════════════╣
║  Step 1: CLASSIFY                                         ║
║  qwen2.5-3b, returns JSON only                            ║
║  → { complexity, skills }                                 ║
╠═══════════════════════════════════════════════════════════╣
║  Step 1.5: POST RULES (hard post-processing rules)        ║
║  skills ≥ 4 → complexity elevated to at least complex     ║
╠═══════════════════════════════════════════════════════════╣
║  Step 2: ROUTE                                            ║
║  Skill Route Override → Three-Tier Policy                 ║
║  → decide: classifier / edge / cloud                         ║
╠═══════════════════════════════════════════════════════════╣
║  Step 3: EXECUTE                                          ║
║  Call the selected model (fallback handled by OpenClaw)   ║
╚════════╦══════════════════╦══════════════╦════════════════╝
         ▼                  ▼              ▼
    llama.cpp          llama.cpp     ex. Google Gemini
    aiDAPTIVLink      aiDAPTIVLink     2.5 Flash
    (classifier)          (edge)          (cloud)
```

---

## 2. Three-Tier Model Architecture

### 2.1 Model Role Overview

| Tier | Available Models | Parameters | Location | Purpose | Port (Example) |
| --- | --- | --- | --- | --- | --- |
| **classifier** | qwen2.5-3b | 3B | Local aiDAPTIVLink | Classifier + lightweight task execution | `127.0.0.1:13142` |
| **edge** | gemma4-26B, qwen3.5-35B, nemotron-120B, qwen3.5-122B | 26B–122B | Local aiDAPTIVLink | Medium-to-high complexity task execution | `127.0.0.1:13141` |
| **cloud** | gemini-2.5-flash, etc. | — | ex. Google Cloud | Highest complexity / multimodal tasks | API endpoint |

**Edge Model to Policy Level Mapping:**

| Model | Recommended Policy |
| --- | --- |
| gemma4-26B | cost-optimize-L2 |
| qwen3.5-35B | cost-optimize-L2 |
| nemotron-120B | cost-optimize-L3 |
| qwen3.5-122B | cost-optimize-L3 |

**Core Design:** The classifier model (qwen2.5-3b) serves dual roles as both classifier and lightweight executor. Depending on the Policy, low-complexity tasks can be answered directly by the classifier model, reducing unnecessary large-model calls and lowering latency and resource consumption. The edge model can be chosen in different sizes based on available hardware, paired with the corresponding Policy Level.

---

## 3. CLASSIFIER

### 3.1 Complexity Levels

The classifier inserts the user input into a prompt, sends it to the **classifier model** specified in the config, and expects it to return a JSON:

```json
{"complexity":"moderate","skills":["coding"]}
```

| Level | Value | Description | Examples |
| --- | --- | --- | --- |
| `trivial` | 0 | Greetings, yes/no, single-word answers, time queries, basic arithmetic | "Hello", "1+1=?" |
| `simple` | 1 | Basic Q&A, simple math, short translation, lookup questions, simple file reads | "Capital of France?", "Translate hello" |
| `moderate` | 2 | Multi-step instructions, code snippets, summaries, writing, file creation, config editing, data analysis, saving/memory storage, most everyday work tasks | "Write a debounce function" |
| `complex` | 3 | System architecture design, deep multi-document synthesis, competitive research reports requiring expert judgment | "Design a microservice architecture" |
| `expert` | 4 | New algorithm design, PhD-level proofs, frontier research | "Implement a distributed consensus algorithm" |

**Full Routing Table per Policy:**

| Complexity | cost-optimize-L1 | cost-optimize-L2<br>(Default) | cost-optimize-L3 | edge-first | cloud-first |
| --- | --- | --- | --- | --- | --- |
| trivial (0) | **edge** | **classifier** | **classifier** | **edge** | **cloud** |
| simple (1) | **edge** | **classifier** | **classifier** | **edge** | **cloud** |
| moderate (2) | **cloud** | **edge** | **edge** | **edge** | **cloud** |
| complex (3) | **cloud** | **cloud** | **edge** | **edge** | **cloud** |
| expert (4) | **cloud** | **cloud** | **cloud** | **edge** | **cloud** |

| Policy Level | Applicable Edge Models | Routing Logic |
| --- | --- | --- |
| **L1** (small ~3B) | qwen2.5-3B (classifier = edge, same model) | 0–1 → edge, 2–4 → cloud |
| **L2** (medium ~26-35B) | gemma4-26B, qwen3.5-35B (classifier = edge, same model) | 0–1 → classifier, 2 → edge, 3–4 → cloud (three-tier split) |
| **L3** (large ~120B) | nemotron-120B, qwen3.5-122B | 0–1 → classifier, 2–3 → edge, 4 → cloud (strongest edge capability) |

> **Note: L3 requires simultaneously running a small ~3B classifier model** (e.g. qwen2.5-3B) as both classifier and lightweight executor. L1 requires only one instance since classifier = edge is the same model.

**Default Policy: `cost-optimize-L2`** (can be overridden in the config file)


### 3.2 Skills (Skill Detection)

Skills are **not configured manually** — the classifier model infers them from the user input.

The prompt tells the model the available skills to choose from (consistent with `classifier-prompt.ts` / `types.ts`):

| Skill | Description | Example Triggers |
| --- | --- | --- |
| `coding` | Writing or debugging **program logic** (functions, classes, scripts); excludes simple file saves, config changes, or writing markdown | "Write a Python class", "This code has a bug" |
| `math` | Mathematical calculations or proofs | "Prove there are infinite primes", "Compute an integral" |
| `creative` | Creative writing, stories, rewrites, blog posts, etc. | "Write a poem", "Help me brainstorm a brand name" |
| `analysis` | Data analysis, comparison, evaluation, report writing | "Compare React and Vue", "Analyze this dataset" |
| `translation` | Language translation | "Translate to English", "Translate this Japanese text to Chinese" |
| `search` | Requires web search for real-time or external information | "Search for the latest React 19 docs" |
| `tool-use` | Requires calling external APIs or executing tools | "Call API to check weather" |
| `image-gen` | Generating images, illustrations, diagrams, visual content | "Draw me a logo", "Generate a poster" |
| `conversation` | Simple chat, greetings | "Hello", "Who are you" |
| `summarization` | Summarizing, condensing information | "Summarize this article for me" |
| `reasoning` | Logical reasoning, multi-step reasoning chains | "How do I solve this logic puzzle" |

The model can return multiple skills, for example:

- "Translate this and search for related info" → `["translation", "search"]`
- "Debug this React state issue" → `["coding"]`

If all returned skills are not in the valid list, or skills is empty, `"conversation"` is automatically added.

**Purpose of Skills:** Used in the Router's Skill Route Override stage to force routing based on the detected skill.

### 3.3 Reason (Generated During Routing)

**Note: The classifier itself does not return a reason.** The `reason` field is a string assembled by the **Router** (routing engine) when making a routing decision, explaining why a particular tier/model was chosen.

Examples (from `router.ts`):

- `"policy=cost-optimize-L2, complexity=trivial, skills=[conversation] -> classifier"`
- `"policy=cost-optimize-L2, complexity=complex, skills=[analysis,coding] -> cloud"`
- `"skill-route: pattern=image-gen, forceTier=cloud, skills=[image-gen], Image generation requires cloud model with multimodal capabilities"`

Purpose: Debugging and logging — appears in file logs and stored via `globalThis` for the host program to read.

### 3.4 Heuristic Fallback (Keyword-based Safety Net)

When the classifier model returns **invalid JSON** (hallucination, timeout, malformed output), the system does not throw an error but instead applies hard rule-based judgment (`heuristic.ts`).

**Step 1: Word Count**

| User input length | Assigned complexity |
| --- | --- |
| < 20 chars | `trivial` (0) |
| 20 ~ 99 chars | `simple` (1) |
| 100 ~ 499 chars | `moderate` (2) |
| >= 500 chars | `complex` (3) |

**Step 2: Keyword Boosting**

| Keywords | Effect |
| --- | --- |
| `code, function, class, import, export, def, const, let, var, async, await, return` | skill +coding, complexity at least moderate |
| `debug, error, bug, fix, crash, exception, traceback, stack trace` | skill +coding, complexity directly elevated to complex |
| `architect, design, system, scale, infrastructure, microservice, distributed` | skill +analysis, complexity directly elevated to complex |
| `translate, 翻譯, 翻译` | skill +translation, complexity at least simple |
| `搜尋, 搜索, search, lookup, find info` | skill +search, complexity at least simple |

If no keyword matches, the default skill is `"conversation"`.

This is the last line of defense; under normal conditions the model returns correct JSON and this path is never reached.

### 3.5 Cache Mechanism

- Uses the **exact same user input string** as the cache key (exact string match, not hash)
- Cache is stored in an in-memory `Map`; cleared on Gateway restart
- Default cache TTL is 300 seconds (5 minutes); expired entries are lazily evicted on the next `get`
- Cache hit skips the model call
- Can be disabled in config: `"cacheEnabled": false`

### 3.6 `/new` or `/reset` Forces a Configured Tier on Startup

When the prompt contains `"A new session was started via /new or /reset"`, **the classifier and routing engine are skipped and the configured tier's model is used directly**. The target tier is controlled by `routing.newSessionTier`, which can be `"classifier"`, `"edge"`, or `"cloud"` and **defaults to `"cloud"`**.

This behavior is implemented in `index.ts`'s `before_model_resolve` hook, intercepting before the classifier is called.

```json
"routing": {
  "newSessionTier": "cloud"   // "classifier" | "edge" | "cloud"
}
```

```
User inputs /new or /reset
  → prompt contains startup message
  → use config.models[newSessionTier]
  → reason = "force-<tier> (new session startup)"
```

**Fail-safe (startup-time static check):** On startup `newSessionTier` is validated; if the value is not a known tier, or the corresponding tier has no `provider`/`model` configured in `config.models`, it automatically falls back to `"cloud"` and emits a `warn` log.

> ⚠ **Note: This fail-safe only validates config completeness; it does not check whether the actual service is reachable.** If the selected tier's endpoint goes down at runtime (e.g. llama.cpp not running, cloud API key invalid), this layer cannot detect it. Runtime failure recovery is handled by the OpenClaw host program; see "Advanced: pairing with OpenClaw host fallback" below.

Design rationale: The first response in a new session strongly impacts UX. The default `"cloud"` (cloud large model) prioritizes the best first-response quality and stability; switch to `"edge"` (large local model) for privacy/offline-sensitive deployments, or `"classifier"` for the fastest fully-local response.

#### Advanced (optional): pairing with OpenClaw host fallback

If you're worried that "the selected tier failing at runtime will simply error out", you can add a fallback chain to `agents.defaults.model.fallbacks`. The OpenClaw host program (`runWithModelFallback`) will try each entry in order when the actual model call fails. A reasonable default is to put "the other two tiers" into fallbacks:

```json
"agents": {
  "defaults": {
    "model": {
      "primary": "llamacpp/qwen2.5-3b-instruct-q4_k_m",
      "fallbacks": [
        "llamacpp-large/gpt-oss-120b-Q4_K_M",
        "openrouter/google/gemini-2.5-flash"
      ]
    }
  }
}
```

| Behavior | Without `fallbacks` | With `fallbacks` |
| --- | --- | --- |
| newSessionTier service healthy | Routes to selected tier ✓ | Routes to selected tier ✓ |
| newSessionTier unreachable at runtime | Host falls back to `primary` model | Host walks down `fallbacks` until one succeeds |
| All models down | Throws error | Throws error |

**Notes:**
- This setting is **completely optional**. Things still work without it (just with a less graceful failure response).
- `fallbacks` references the user's host-level model list and **is not directly coupled to the hybrid-gateway classifier/edge/cloud tier concept** — the host only knows `provider/model` strings, not plugin tiers.
- This fallback fires **only after a runtime call has failed**; it is not a pre-flight health check, so the **first failure still pays its full timeout cost** before the next candidate is tried.
- Scope covers all hybrid-gateway routing decisions (not just new session): Stage 2 Policy routing, Skill Route Override, etc.

### 3.7 Bypass Patterns (Skip Routing)

When the prompt matches a configured bypass pattern, the **entire routing flow is skipped**, letting OpenClaw handle the request with its default model without any routing intervention.

This behavior is implemented in `index.ts`'s `before_model_resolve` hook, intercepting before the classifier is called.

```json
"bypassPatterns": ["^/admin", "internal-debug"]
```

- `bypassPatterns` is a string array; each entry is a **RegExp pattern** (case-insensitive)
- The first match stops processing and returns `undefined` (letting OpenClaw use its default model)
- If `bypassPatterns` is not set or is empty, no interception occurs

Design rationale: Special commands, system messages, or debug paths may not need to go through routing logic; bypass allows them to skip it directly.

### 3.8 Disable Thinking (Suppress Thinking Mode)

The classifier supports a `disableThinking` option to reduce classification latency. When enabled, the strategy is automatically selected based on `thinkingStrategy` or the model name:

| Strategy | Applicable Models | Implementation |
| --- | --- | --- |
| `gemma4-raw` | Gemma 4 series | Uses `/v1/completions` (raw completions), bypasses chat template to avoid injecting `<\|think\|>` |
| `qwen-nothink` | Qwen series (default) | Appends `/nothink` suffix at the end of the system prompt |
| `auto`<br>(Default) | — | Auto-detect: model name contains `gemma4` → `gemma4-raw`, otherwise → `qwen-nothink` |

When `disableThinking` is not enabled, the standard `chat.completions` API is used, and thinking behavior is controlled by the server's chat template.

### 3.9 Post Rules (Hard Post-Processing Rules)

After the classifier returns results but before entering the Router, **code-level hard post-processing rules** (`applyPostRules` in `classifier.ts`) are executed to ensure complexity does not fall below a specified threshold under certain conditions. These rules do not rely on the classifier model's judgment and are 100% deterministic.

**Current Rules:**

| Condition | Effect |
| --- | --- |
| Number of detected skills **≥ 4** | Complexity is automatically elevated to at least **`complex`** (unchanged if already ≥ complex) |

**Design Rationale:** When a task involves multiple skills (e.g. analysis + creative + coding + reasoning), even if each sub-task is only moderate level individually, the combined task's overall complexity and output quality requirements are typically higher, warranting a more capable model.

**Example:**

```
Classifier raw result: complexity=moderate, skills=[analysis,creative,coding,reasoning] (4 skills)
After Post Rules:      complexity=complex,  skills=[analysis,creative,coding,reasoning]
Log output:            [hybrid-gw] post-rule: moderate -> complex (4 skills >= 4)
```

**Scope:** Applied to both model classification results and heuristic fallback results.

**Adjustment:** Modify the `minSkills` (threshold skill count) and `floor` (minimum complexity level) values of the `SKILL_COUNT_COMPLEXITY_FLOOR` constant in `classifier.ts`.

---

## 4. ROUTER (Routing Engine)

The Router receives the classification result (after Post Rules processing) and determines routing in **two stages**:

```
Classification result { complexity, skills }
  │
  ▼
[Post Rules] skills ≥ 4 → complexity at least complex
  │
  ▼
[Stage 1] Skill Route Override → matched? → decide model directly, skip Stage 2
  │
  ▼ (no match)
[Stage 2] Three-Tier Routing Policy → determine tier (classifier / edge / cloud) based on complexity
  │
  ▼
Final model selected → RoutingDecision
```

### 4.1 Skill Route Override

**Highest priority.** If a skill detected by the classifier matches any skillRoute rule, the model is decided directly **without consulting the Policy**.

**Current config: Only one Skill Route — `image-gen` → force cloud.** All other skills go through Stage 2's Routing Policy.

Config location: `openclaw.json` → `plugins.entries.hybrid-gateway.config.routing.skillRoutes`

```json
"skillRoutes": [
  {
    "skillPattern": "image-gen",
    "forceTier": "cloud",
    "reason": "Image generation requires cloud model with multimodal capabilities"
  }
]
```

#### Available skillPattern Values

`skillPattern` is a **regular expression** (regex) that matches each skill string in the skills array returned by the classifier.

Available skill strings (corresponding to the classifier prompt; use this table when adding new Overrides):

| skillPattern | Matched Skill | Description |
| --- | --- | --- |
| `"coding"` | coding | Program logic / debugging |
| `"math"` | math | Mathematical calculations |
| `"creative"` | creative | Creative writing |
| `"analysis"` | analysis | Analysis / comparison |
| `"translation"` | translation | Translation |
| `"search"` | search | Web search / external data |
| `"tool-use"` | tool-use | Tools / API |
| `"image-gen"` | image-gen | Image generation (**currently the only Override**) |
| `"conversation"` | conversation | Simple chat |
| `"summarization"` | summarization | Summarization |
| `"reasoning"` | reasoning | Logical reasoning |

Because it's a regex, future rules can be combined, e.g. `"image-gen|tool-use"`.

Each rule has two ways to specify the target:

| Field | Description |
| --- | --- |
| `forceTier` | Force a specific tier, using the corresponding provider/model in `config.models` |
| `preferModel` | When this field has a value (truthy), use the `forceTier` (default `"cloud"`) tier mapping |

**Actual behavior (`router.ts`):** The code first checks if `preferModel` has a value; if so, uses the `forceTier ?? "cloud"` tier; otherwise checks `forceTier`. `preferModel` currently serves as a trigger condition for the priority branch; its string value itself is not used as a model lookup key.

**Note: Rules are scanned top-to-bottom; the first match stops processing.**

### 4.2 Three-Tier Routing Policy

Policy evaluation only occurs when **no Skill Route matches**.

Policy is divided into L1/L2/L3 levels based on edge model capability, with thresholds adjusted according to model capability.

#### Five-Policy Behavior Comparison Table

| Detected Complexity | `edge-first` | `cloud-first` | `cost-optimize-L1` | `cost-optimize-L2`<br>(Default) | `cost-optimize-L3` |
| --- | --- | --- | --- | --- | --- |
| trivial (0) | **edge** | **cloud** | **edge** | **classifier** | **classifier** |
| simple (1) | **edge** | **cloud** | **edge** | **classifier** | **classifier** |
| moderate (2) | **edge** | **cloud** | **cloud** | **edge** | **edge** |
| complex (3) | **edge** | **cloud** | **cloud** | **cloud** | **edge** |
| expert (4) | **edge** | **cloud** | **cloud** | **cloud** | **cloud** |

Design rationale for each Policy:

| Policy | Rationale |
| --- | --- |
| `edge-first` | **Maximize local models**: always route to edge, never cloud, never classifier. |
| `cloud-first` | **Always cloud**: route everything to cloud. |
| `cost-optimize-L1` | **Small edge model (~3B)**: 0–1 → edge (= classifier, same model), 2–4 → cloud. Model too small to handle moderate+ tasks. |
| `cost-optimize-L2` | **Medium edge model (~26-35B)**: 0–1 → classifier (same edge model), 2 → edge, 3–4 → cloud. Balances performance and cost. |
| `cost-optimize-L3` | **Large edge model (~120B)**: 0–1 → classifier (3B), 2–3 → edge, 4 → cloud. Strongest edge capability; only expert tasks go to cloud. |



### 4.3 RoutingDecision Output Example

Default Policy: **cost-optimize-L2** (Default). Below is a complete single-flow example (edge model shown as **gemma4-26B**; actual `model` is determined by `config.models.edge`).

#### "Write a binary search in Python" → edge (gemma4-26B)

```
Classify: complexity=moderate, skills=[coding]
Skill Route: no match (currently only image-gen has Override)
Policy: cost-optimize-L2, moderate(2) → edge

RoutingDecision:
  model:    gemma4-26B
  tier:     edge
  reason:   "policy=cost-optimize-L2, complexity=moderate, skills=[coding] -> edge"
```

---

## 5. Fallback (Three-Tier Fallback Chain)

> **Implementation Status:** `fallbackEnabled` is defined in `types.ts` and the config file, but **the three-tier fallback logic is not implemented in this plugin's .ts files**. This plugin is responsible only for routing decisions (determining provider/model); actual execution failure fallback should be handled by the **OpenClaw host program**.

### 5.1 Expected Fallback Order

| Original Tier | First Fallback | Second Fallback | All Failed |
| --- | --- | --- | --- |
| classifier (3B) down | → edge (120B) | → cloud | Return error |
| edge (120B) down | → cloud | → classifier (3B) | Return error |
| cloud down | → edge (120B) | → classifier (3B) | Return error |

Can be disabled in config: `"fallbackEnabled": false`

---

## 6. Routing Decision Storage

This plugin stores the last routing decision in `globalThis` for the OpenClaw host program to read:

```typescript
// Storage structure (index.ts)
{ tier: string, provider: string, model: string, reason: string, ts: number }
```

It also writes to a file log:
- Windows: `C:\tmp\openclaw\hybrid-gateway.log`
- Other: `/tmp/openclaw/hybrid-gateway.log`

Log format: `timestamp | tier | provider/model | complexity=... skills=[...] | "prompt preview..."`

---

## 7. Config File Structure (openclaw.json Reference)

Below is the config file structure for the three-tier architecture (corresponding to `plugins.entries.hybrid-gateway.config` in `openclaw.json`):

```json
{
  "classifier": {
    "mode": "model",
    "baseUrl": "http://127.0.0.1:13142/v1",
    "apiKey": "empty",
    "model": "qwen2.5-3b-instruct-q4_k_m",
    "maxLatencyMs": 30000,
    "cacheEnabled": true,
    "cacheTtlSeconds": 300,
    "disableThinking": false,
    "thinkingStrategy": "auto"
  },
  "models": {
    "classifier": {
      "provider": "llamacpp",
      "model": "qwen2.5-3b-instruct-q4_k_m"
    },
    "edge": {
      "provider": "llamacpp-large",
      "model": "gpt-oss-120b-Q4_K_M"
    },
    "cloud": {
      "provider": "openrouter",
      "model": "google/gemini-2.5-flash"
    }
  },
  "routing": {
    "policy": "cost-optimize-L2",
    "skillRoutes": [
      {
        "skillPattern": "image-gen",
        "forceTier": "cloud",
        "reason": "Image generation requires cloud model with multimodal capabilities"
      }
    ],
    "fallbackEnabled": true,
    "bypassPatterns": [],
    "newSessionTier": "cloud"
  }
}
```

---
