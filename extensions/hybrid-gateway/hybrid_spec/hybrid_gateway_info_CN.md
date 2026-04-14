# Hybrid Gateway — 說明文件

---

## 一、整體流程

```
User Input
  │
  ▼
╔═══════════════════════════════════════════════════════════╗
║  Pre-check: New Session / Bypass                          ║
║  • /new 或 /reset → 強制 cloud，跳過後續                    ║
║  • Bypass pattern 命中 → 交還 OpenClaw 預設模型              ║
╠═══════════════════════════════════════════════════════════╣
║  Step 1: CLASSIFY（分類器）                                ║
║  qwen2.5-3b，只回 JSON                                     ║
║  → { complexity, skills }                                   ║
╠═══════════════════════════════════════════════════════════╣
║  Step 1.5: POST RULES（後處理硬規則）                       ║
║  skills ≥ 4 → complexity 至少 complex                       ║
╠═══════════════════════════════════════════════════════════╣
║  Step 2: ROUTE（路由引擎）                                 ║
║  Skill Route Override → Three-Tier Policy                   ║
║  → 決定走 gateway / edge / cloud                            ║
╠═══════════════════════════════════════════════════════════╣
║  Step 3: EXECUTE（執行）                                   ║
║  呼叫選定的模型（fallback 由 OpenClaw 主程式處理）            ║
╚════════╦══════════════════╦══════════════╦════════════════╝
         ▼                  ▼              ▼
    llama.cpp          llama.cpp     ex. Google Gemini
    aiDAPTIVLink      aiDAPTIVLink     2.5 Flash
    (gateway)          (edge)          (cloud)
```

---

## 二、三層模型架構

### 2.1 模型角色一覽

| Tier | 可用模型 | 參數量 | 位置 | 用途 | 端口（範例） |
| --- | --- | --- | --- | --- | --- |
| **gateway** | qwen2.5-3b | 3B | 本地 aiDAPTIVLink | 分類器 + 簡單任務執行 | `127.0.0.1:13142` |
| **edge** | gemma4-26B、qwen3.5-35B、nemotron-120B、qwen3.5-122B | 26B–122B | 本地 aiDAPTIVLink | 中高複雜度任務執行 | `127.0.0.1:13141` |
| **cloud** | gemini-2.5-flash 等 | — | ex. Google Cloud | 最高複雜度 / 多模態任務 | API endpoint |

**Edge 模型與 Policy Level 對應：**

| 模型 | 建議 Policy |
| --- | --- |
| gemma4-26B | cost-optimize-L2 |
| qwen3.5-35B | cost-optimize-L2 |
| nemotron-120B | cost-optimize-L3 |
| qwen3.5-122B | cost-optimize-L3 |

**核心設計：** gateway 模型（qwen2.5-3b）同時承擔分類器和輕量執行兩個角色。依 Policy 不同，低複雜度任務可直接由分類器模型回應，減少不必要的大模型呼叫，降低延遲與資源消耗。Edge 模型可依硬體資源選擇不同大小，並搭配對應的 Policy Level。

---

## 三、CLASSIFIER（分類器）

### 3.1 Complexity 分級

分類器把 user input 塞進一個 prompt，送給設定檔中的 **classifier 模型**，要求它回傳一個 JSON：

```json
{"complexity":"moderate","skills":["coding"]}
```

| 等級 | 數值 | 說明 | 範例 |
| --- | --- | --- | --- |
| `trivial` | 0 | 打招呼、yes/no、單字回答、時間查詢、純四則運算 | "你好"、"1+1=?" |
| `simple` | 1 | 基本問答、簡單數學、短翻譯、查詢型問題、簡單檔案讀取 | "法國首都？"、"翻譯 hello" |
| `moderate` | 2 | 多步驟指令、程式片段、摘要、寫作、檔案建立、設定編輯、資料分析、存檔/記憶儲存、大多數日常工作任務 | "寫個 debounce function" |
| `complex` | 3 | 系統架構設計、多文件深度綜合、需要專家判斷的競爭研究報告 | "設計微服務架構" |
| `expert` | 4 | 新演算法設計、博士級證明、前沿研究 | "實作分散式共識算法" |

**各 Policy 的路由對應表（完整）：**

| Complexity | cost-optimize-L1 | cost-optimize-L2<br>(Default) | cost-optimize-L3 | edge-first | cloud-first |
| --- | --- | --- | --- | --- | --- |
| trivial (0) | **edge** | **gateway** | **gateway** | **edge** | **cloud** |
| simple (1) | **edge** | **gateway** | **gateway** | **edge** | **cloud** |
| moderate (2) | **cloud** | **edge** | **edge** | **edge** | **cloud** |
| complex (3) | **cloud** | **cloud** | **edge** | **edge** | **cloud** |
| expert (4) | **cloud** | **cloud** | **cloud** | **edge** | **cloud** |

| Policy Level | 適用 Edge 模型 | 路由邏輯 |
| --- | --- | --- |
| **L1**（小型 ~3B） | qwen2.5-3B（gateway = edge 同一模型） | 0–1 → edge，2–4 → cloud |
| **L2**（中型 ~26-35B） | gemma4-26B、qwen3.5-35B（建議gateway = edge 同一模型）| 0–1 → gateway，2 → edge，3–4 → cloud |
| **L3**（大型 ~120B） | nemotron-120B、qwen3.5-122B | 0–1 → gateway，2–3 → edge，4 → cloud（邊緣能力最強） |

> **注意：L3 需要同時運行一個小型 ~3B gateway 模型**（如 qwen2.5-3B）作為分類器與輕量執行。L1 因 gateway = edge 為同一模型，只需啟動一個實例。

**預設 Policy：`cost-optimize-L2`**（可在設定檔覆寫）


### 3.2 Skills（技能偵測）

Skills **不是手動設定的**，是分類器模型自己從 user input 判斷出來的。

Prompt 裡告訴模型可以選的 skill 有這些（與 `classifier-prompt.ts` / `types.ts` 一致）：

| Skill | 說明 | 範例觸發 |
| --- | --- | --- |
| `coding` | 撰寫或除錯**程式邏輯**（函式、類別、腳本）；不含單純存檔、改設定、寫 markdown | "寫個 Python class"、"這段 code 有 bug" |
| `math` | 數學計算或證明 | "證明質數有無限多"、"計算積分" |
| `creative` | 創意寫作、故事、改寫、部落格等 | "寫一首詩"、"幫我想個品牌名" |
| `analysis` | 資料分析、比較、評估、報告撰寫 | "比較 React 和 Vue"、"分析這組數據" |
| `translation` | 語言翻譯 | "翻譯成英文"、"把這段日文翻中文" |
| `search` | 需要網搜即時或外部資訊 | "搜尋最新的 React 19 文件" |
| `tool-use` | 需要呼叫外部 API 或執行工具 | "呼叫 API 查天氣" |
| `image-gen` | 產生圖像、插圖、示意圖、視覺內容 | "幫我畫一張 logo"、"生成一張海報" |
| `conversation` | 簡單聊天、打招呼 | "你好"、"你是誰" |
| `summarization` | 摘要、濃縮資訊 | "幫我總結這篇文章" |
| `reasoning` | 邏輯推理、多步推理鏈 | "這個邏輯題怎麼解" |

模型可以回傳多個 skills，例如：

- "翻譯這段話然後搜尋相關資料" → `["translation", "search"]`
- "debug 這個 React 的 state 問題" → `["coding"]`

如果回傳的 skills 全不在合法清單中，或 skills 為空，會自動補上 `"conversation"`。

**Skills 的用途：** 在 Router 的 Skill Route Override 階段，根據偵測到的 skill 強制路由。

### 3.3 Reason（路由階段產生）

**注意：分類器本身不回傳 reason。** `reason` 欄位是 **Router**（路由引擎）在做出路由決策時自行組裝的字串，用於說明為何選擇該 tier/model。

範例（來自 `router.ts`）：

- `"policy=cost-optimize-L2, complexity=trivial, skills=[conversation] -> gateway"`
- `"policy=cost-optimize-L2, complexity=complex, skills=[analysis,coding] -> cloud"`
- `"skill-route: pattern=image-gen, forceTier=cloud, skills=[image-gen], Image generation requires cloud model with multimodal capabilities"`

用途：debug 和日誌記錄，會出現在檔案日誌中以及透過 globalThis 儲存供主程式讀取。

### 3.4 Heuristic Fallback（關鍵字兜底）

當分類器模型回傳的 **不是合法 JSON** 時（模型幻覺、timeout、格式亂掉），系統不會報錯，而是用純規則硬判（`heuristic.ts`）。

**第一步：字數判斷**

| user input 長度 | 判定 complexity |
| --- | --- |
| < 20 字 | `trivial` (0) |
| 20 ~ 99 字 | `simple` (1) |
| 100 ~ 499 字 | `moderate` (2) |
| >= 500 字 | `complex` (3) |

**第二步：關鍵字加碼**

| 關鍵字 | 效果 |
| --- | --- |
| `code, function, class, import, export, def, const, let, var, async, await, return` | skill +coding，complexity 至少 moderate |
| `debug, error, bug, fix, crash, exception, traceback, stack trace` | skill +coding，complexity 直接升 complex |
| `architect, design, system, scale, infrastructure, microservice, distributed` | skill +analysis，complexity 直接升 complex |
| `translate, 翻譯, 翻译` | skill +translation，complexity 至少 simple |
| `搜尋, 搜索, search, lookup, find info` | skill +search，complexity 至少 simple |

如果沒有命中任何關鍵字，預設 skill 為 `"conversation"`。

這是最後防線，正常情況下模型會正確回 JSON，不會走到這裡。

### 3.5 Cache 機制

- 使用 **完全相同的 user input 字串** 做為 cache key（exact string match，非 hash）
- Cache 存放在記憶體內的 `Map`，Gateway 重啟後清空
- Cache TTL 預設 300 秒（5 分鐘），過期條目在下次 `get` 時惰性清除
- 命中 cache 時跳過模型呼叫
- 可在設定檔關閉：`"cacheEnabled": false`

### 3.6 `/new` 或 `/reset` 啟動時強制上雲

當 prompt 中包含 `"A new session was started via /new or /reset"` 時，**跳過分類器與路由引擎，直接強制走 cloud 模型**。

此行為在 `index.ts` 的 `before_model_resolve` hook 中實作，邏輯在分類器呼叫之前就攔截。

```
User 輸入 /new 或 /reset
  → prompt 包含啟動訊息
  → 直接走 cloud（config.models.cloud）
  → reason = "force-cloud (new session startup)"
```

設計考量：新 session 的第一次回應品質影響使用體驗，因此一律用雲端模型。

### 3.7 Bypass Patterns（繞過路由）

當 prompt 內容符合設定的 bypass pattern 時，**跳過整個路由流程**，讓 OpenClaw 使用預設模型處理，不介入任何路由決定。

此行為在 `index.ts` 的 `before_model_resolve` hook 中實作，在分類器呼叫之前攔截。

```json
"bypassPatterns": ["^/admin", "internal-debug"]
```

- `bypassPatterns` 是字串陣列，每條皆為 **RegExp pattern**（大小寫不敏感）
- 第一條命中即停止，回傳 `undefined`（讓 OpenClaw 用預設 model）
- 未設定 `bypassPatterns` 或陣列為空時，不做任何攔截

設計考量：特殊指令、系統訊息或除錯路徑可能不希望走路由邏輯，透過 bypass 可直接繞過。

### 3.8 Disable Thinking（抑制思考模式）

分類器支援 `disableThinking` 選項，減少分類延遲。啟用時依 `thinkingStrategy` 或模型名稱自動選擇策略：

| 策略 | 適用模型 | 實作方式 |
| --- | --- | --- |
| `gemma4-raw` | Gemma 4 系列 | 使用 `/v1/completions`（raw completions），繞過 chat template，避免注入 `<\|think\|>` |
| `qwen-nothink` | Qwen 系列（預設） | 在 system prompt 末尾加上 `/nothink` 後綴 |
| `auto`<br>(Default) | — | 自動偵測：模型名含 `gemma4` → `gemma4-raw`，否則 → `qwen-nothink` |

未啟用 `disableThinking` 時，使用標準 `chat.completions` API，思考行為由 server 的 chat template 控制。

### 3.9 Post Rules（後處理硬規則）

分類器回傳結果後、進入 Router 之前，會執行**程式碼層級的硬規則後處理**（`classifier.ts` 中的 `applyPostRules`），確保特定條件下 complexity 不低於指定門檻。此規則不依賴分類器模型的判斷，具 100% 確定性。

**目前規則：**

| 條件 | 效果 |
| --- | --- |
| 偵測到的 skills 數量 **≥ 4** | complexity 自動提升至至少 **`complex`**（若已 ≥ complex 則不變） |

**設計考量：** 當一個任務涉及多種技能（如 analysis + creative + coding + reasoning），即使每個子任務本身只是 moderate 等級，組合起來的整體任務複雜度與輸出品質需求通常更高，應交由更強的模型處理。

**範例：**

```
分類器原始結果: complexity=moderate, skills=[analysis,creative,coding,reasoning]（4 skills）
Post Rules 後:  complexity=complex,  skills=[analysis,creative,coding,reasoning]
日誌輸出:       [hybrid-gw] post-rule: moderate -> complex (4 skills >= 4)
```

**適用範圍：** 同時套用於模型分類結果與 heuristic fallback 結果。

**調整方式：** 修改 `classifier.ts` 中 `SKILL_COUNT_COMPLEXITY_FLOOR` 常數的 `minSkills`（門檻技能數）和 `floor`（最低 complexity 等級）。

---

## 四、ROUTER（路由引擎）

Router 收到分類結果（經 Post Rules 後處理）後，依 **兩階段** 決定路由：

```
分類結果 { complexity, skills }
  │
  ▼
[Post Rules] skills ≥ 4 → complexity 至少 complex
  │
  ▼
[Stage 1] Skill Route Override → 命中？ → 直接決定模型，跳過 Stage 2
  │
  ▼（沒命中）
[Stage 2] Three-Tier Routing Policy → 根據 complexity 決定 tier (gateway / edge / cloud)
  │
  ▼
選出最終模型 → RoutingDecision
```

### 4.1 Skill Route Override（技能路由覆蓋）

**最高優先權。** 如果分類器偵測到的 skill 命中了任何 skillRoute 規則，直接決定模型，**不再看 Policy**。

**目前設定：只有一條 Skill Route — `image-gen` → 強制上雲。** 其餘 skill 一律走 Stage 2 的 Routing Policy。

設定位置：`openclaw.json` → `plugins.entries.hybrid-gateway.config.routing.skillRoutes`

```json
"skillRoutes": [
  {
    "skillPattern": "image-gen",
    "forceTier": "cloud",
    "reason": "Image generation requires cloud model with multimodal capabilities"
  }
]
```

#### skillPattern 可用的值

`skillPattern` 是 **正則表達式**（regex），匹配分類器回傳的 skills 陣列中的每個 skill 字串。

可用的 skill 字串（對應分類器 prompt；要擴充 Override 時可從此表挑）：

| skillPattern | 匹配的 skill | 說明 |
| --- | --- | --- |
| `"coding"` | coding | 程式邏輯 / 除錯 |
| `"math"` | math | 數學計算 |
| `"creative"` | creative | 創意寫作 |
| `"analysis"` | analysis | 分析 / 比較 |
| `"translation"` | translation | 翻譯 |
| `"search"` | search | 網搜 / 外部資料 |
| `"tool-use"` | tool-use | 工具 / API |
| `"image-gen"` | image-gen | 圖像生成（**目前唯一 Override**） |
| `"conversation"` | conversation | 簡單聊天 |
| `"summarization"` | summarization | 摘要 |
| `"reasoning"` | reasoning | 邏輯推理 |

因為是 regex，之後若要加規則可組合，例如 `"image-gen|tool-use"`。

每條 rule 有兩種指定目標的方式：

| 欄位 | 說明 |
| --- | --- |
| `forceTier` | 強制走某個 tier，使用該 tier 在 `config.models` 中對應的 provider/model |
| `preferModel` | 當此欄位有值（truthy）時，使用 `forceTier`（預設 `"cloud"`）的 tier mapping |

**實際行為（`router.ts`）：** 程式先檢查 `preferModel` 是否有值，有的話走 `forceTier ?? "cloud"` tier；否則再檢查 `forceTier`。`preferModel` 目前作為優先分支的觸發條件，其字串值本身不作為模型查詢依據。

**注意：規則是從上到下掃描的，第一條命中就停止。**

### 4.2 Three-Tier Routing Policy（三層路由策略）

只有在**沒有任何 Skill Route 命中**時才進入 Policy 判斷。

Policy 依 edge 模型能力分為 L1/L2/L3 三級，閾值隨模型能力調整。

#### 五種 Policy 行為對照表

| 偵測到的 complexity | `edge-first` | `cloud-first` | `cost-optimize-L1` | `cost-optimize-L2`<br>(Default) | `cost-optimize-L3` |
| --- | --- | --- | --- | --- | --- |
| trivial (0) | **edge** | **cloud** | **edge** | **gateway** | **gateway** |
| simple (1) | **edge** | **cloud** | **edge** | **gateway** | **gateway** |
| moderate (2) | **edge** | **cloud** | **cloud** | **edge** | **edge** |
| complex (3) | **edge** | **cloud** | **cloud** | **cloud** | **edge** |
| expert (4) | **edge** | **cloud** | **cloud** | **cloud** | **cloud** |

各 Policy 的設計思路：

| Policy | 思路 |
| --- | --- |
| `edge-first` | **最大化本地模型**：一律走 edge，不上雲，不走 gateway。 |
| `cloud-first` | **全走雲端**：一律 cloud。 |
| `cost-optimize-L1` | **小型 edge 模型（~3B）**：0–1 → edge（= gateway，同一模型），2–4 → cloud。模型太小無法處理中等以上任務。 |
| `cost-optimize-L2` | **中型 edge 模型（~26-35B）**：0–1 → gateway（同edge model），2 → edge，3–4 → cloud。兼顧效能與成本。 |
| `cost-optimize-L3` | **大型 edge 模型（~120B）**：0–1 → gateway（3B），2–3 → edge，4 → cloud。邊緣能力最強，僅 expert task上雲。 |



### 4.3 RoutingDecision 輸出範例

預設 Policy：**cost-optimize-L2**（Default）。以下為單一完整流程範例（edge 模型以 **gemma4-26B** 為例，實際 `model` 以 `config.models.edge` 為準）。

#### 「幫我寫一個 Python 的 binary search」→ edge（gemma4-26B）

```
分類: complexity=moderate, skills=[coding]
Skill Route: 無命中（目前只有 image-gen 有 Override）
Policy: cost-optimize-L2, moderate(2) → edge

RoutingDecision:
  model:    gemma4-26B
  tier:     edge
  reason:   "policy=cost-optimize-L2, complexity=moderate, skills=[coding] -> edge"
```

---

## 五、Fallback（三層遞補）

> **實作狀態：** `fallbackEnabled` 在 `types.ts` 和設定檔中定義，但 **三層遞補邏輯不在此 plugin 的 .ts 檔案中實作**。此 plugin 僅負責路由決策（決定 provider/model），實際的執行失敗遞補應由 **OpenClaw 主程式** 處理。

### 5.1 預期 Fallback 遞補順序

| 原始 Tier | 第一 Fallback | 第二 Fallback | 全部失敗 |
| --- | --- | --- | --- |
| gateway (3B) 掛了 | → edge (120B) | → cloud | 回傳錯誤 |
| edge (120B) 掛了 | → cloud | → gateway (3B) | 回傳錯誤 |
| cloud 掛了 | → edge (120B) | → gateway (3B) | 回傳錯誤 |

可在設定關閉：`"fallbackEnabled": false`

---

## 六、路由決策儲存

此 plugin 將最後一次路由決策存入 `globalThis`，供 OpenClaw 主程式讀取：

```typescript
// 儲存結構（index.ts）
{ tier: string, provider: string, model: string, reason: string, ts: number }
```

同時也寫入檔案日誌：
- Windows: `C:\tmp\openclaw\hybrid-gateway.log`
- 其他: `/tmp/openclaw/hybrid-gateway.log`

日誌格式：`timestamp | tier | provider/model | complexity=... skills=[...] | "prompt preview..."`

---

## 七、設定檔結構（openclaw.json 對照）

以下為三層架構的設定檔結構（對應 `openclaw.json` 的 `plugins.entries.hybrid-gateway.config`）：

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
    "gateway": {
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
    "bypassPatterns": []
  }
}
```

---
