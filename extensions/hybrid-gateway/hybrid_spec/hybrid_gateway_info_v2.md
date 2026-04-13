# Hybrid Gateway v2 — 三層路由機制說明文件

> 環境（對齊 `hybrid-gateway.json`）：**分類器 / Gateway 執行模型** 共用 qwen2.5-3b（llama.cpp，例如 `127.0.0.1:13142`），只回 JSON 做分類，同時也作為 complexity 0–2 的執行模型；**Edge 執行模型** 為 gpt-oss-120B（llama.cpp `13141`）；**Cloud 執行模型** 為 **Gemini 2.5 Flash**。

---

## 一、整體流程

```
User Input
  │
  ▼
╔═══════════════════════════════════════════════════════╗
║  Step 1: CLASSIFY（分類器）                            ║
║  qwen2.5-3b，只回 JSON                                 ║
║  → { complexity, skills }                               ║
╠═══════════════════════════════════════════════════════╣
║  Step 2: ROUTE（路由引擎）                             ║
║  Skill Route Override（僅 image-gen）→ Three-Tier Policy║
║  → 決定走 gateway / edge / cloud                        ║
╠═══════════════════════════════════════════════════════╣
║  Step 3: EXECUTE（執行）                               ║
║  呼叫選定的模型，失敗自動 fallback（三層遞補）            ║
╚════════╦══════════════════╦══════════════╦════════════╝
         ▼                  ▼              ▼
    llama.cpp          llama.cpp       Google Gemini
    qwen2.5-3b         gpt-oss-120B   2.5 Flash
    (gateway)          (edge)          (cloud)
```

### v1 → v2 架構差異摘要

| 項目 | v1（二層） | v2（三層） |
| --- | --- | --- |
| Tier 數量 | 2（edge / cloud） | 3（gateway / edge / cloud） |
| 分類器模型 | qwen2.5-3b（僅做分類） | qwen2.5-3b（分類 + 執行 gateway tier） |
| complexity 0,1 | → edge（120B） | → **gateway（3B）** |
| complexity 2 | → edge（120B） | → **edge（120B）**（中型任務走本地大模型） |
| complexity 3,4 | → cloud | → **cloud**（複雜/專家任務直接上雲） |
| Fallback | 雙向（edge ↔ cloud） | 三層遞補鏈（gateway → edge → cloud） |

---

## 二、三層模型架構

### 2.1 模型角色一覽

| Tier | 模型 | 參數量 | 位置 | 用途 | 端口（範例） |
| --- | --- | --- | --- | --- | --- |
| **gateway** | qwen2.5-3b | 3B | 本地 llama.cpp | 分類器 + 簡單任務執行 | `127.0.0.1:13142` |
| **edge** | gpt-oss-120b | 120B | 本地 llama.cpp | 中高複雜度任務執行 | `127.0.0.1:13141` |
| **cloud** | gemini-2.5-flash | — | Google Cloud | 最高複雜度 / 多模態任務 | API endpoint |

**核心設計：** gateway 模型（qwen2.5-3b）同時承擔分類器和輕量執行兩個角色。對於 complexity 0–2 的任務，分類完成後可直接由同一模型回應，減少不必要的大模型呼叫，降低延遲與資源消耗。

---

## 三、CLASSIFIER（分類器）

### 3.1 Complexity 分級

分類器把 user input 塞進一個 prompt，送給設定檔中的 **classifier 模型**（qwen2.5-3b），要求它回傳一個 JSON：

```json
{"complexity":"moderate","skills":["coding"]}
```

| 等級 | 數值 | 說明 | 範例 | 路由目標 |
| --- | --- | --- | --- | --- |
| `trivial` | 0 | 打招呼、yes/no、單字回答、時間查詢 | "你好"、"現在幾點" | **gateway (3B)** |
| `simple` | 1 | 基本問答、簡單數學、短翻譯、查詢型問題、簡單檔案讀取 | "法國首都？"、"1+1=?" | **gateway (3B)** |
| `moderate` | 2 | 多步驟指令、程式片段、摘要、寫作、檔案建立、設定編輯、資料分析、存檔/記憶儲存、大多數日常工作任務 | "寫個 debounce function" | **edge (120B)** |
| `complex` | 3 | 系統架構設計、多文件深度綜合、需要專家判斷的競爭研究報告 | "設計微服務架構" | **cloud** |
| `expert` | 4 | 新演算法設計、博士級證明、前沿研究 | "實作分散式共識算法" | **cloud** |

**判斷邏輯（三層路由）：**

- complexity 0, 1 → **gateway**（本地 3B）
- complexity 2 → **edge**（本地 120B）
- complexity 3, 4 → **cloud**（Gemini 2.5 Flash）

Prompt 中的校準指引（與 `classifier-prompt.ts` 一致）：**大多數任務應判為 "moderate"。只有需要跨多個領域的深度專業知識時才判 "complex"。存檔 / 記憶儲存一律最多 "moderate"。**

### 3.2 Skills（技能偵測）

Skills **不是你手動設定的**，是分類器模型自己從 user input 判斷出來的。

Prompt 裡告訴模型可以選的 skill 有這些（與 `classifier-prompt.ts` / `types.ts` 一致；**含新增的 `image-gen`**）：

| Skill | 說明 | 範例觸發 |
| --- | --- | --- |
| `coding` | 撰寫或除錯**程式邏輯**（函式、類別、腳本）；不含單純存檔、改設定、寫 markdown | "寫個 Python class"、"這段 code 有 bug" |
| `math` | 數學計算或證明 | "證明質數有無限多"、"計算積分" |
| `creative` | 創意寫作、故事、改寫、部落格等 | "寫一首詩"、"幫我想個品牌名" |
| `analysis` | 資料分析、比較、評估、報告撰寫 | "比較 React 和 Vue"、"分析這組數據" |
| `translation` | 語言翻譯 | "翻譯成英文"、"把這段日文翻中文" |
| `search` | 需要網搜即時或外部資訊 | "搜尋最新的 React 19 文件" |
| `tool-use` | 需要呼叫外部 API 或執行工具 | "呼叫 API 查天氣" |
| `image-gen` | **產生圖像、插圖、示意圖、視覺內容** | "幫我畫一張 logo"、"生成一張海報" |
| `conversation` | 簡單聊天、打招呼 | "你好"、"你是誰" |
| `summarization` | 摘要、濃縮資訊 | "幫我總結這篇文章" |
| `reasoning` | 邏輯推理、多步推理鏈 | "這個邏輯題怎麼解" |

模型可以回傳多個 skills，例如：

- "翻譯這段話然後搜尋相關資料" → `["translation", "search"]`
- "debug 這個 React 的 state 問題" → `["coding"]`

**Skills 的用途：** 在 Router 的 Skill Route Override 階段，根據偵測到的 skill 強制路由。

### 3.3 Reason（路由階段產生）

**注意：分類器本身不回傳 reason。** `reason` 欄位是 **Router**（路由引擎）在做出路由決策時自行組裝的字串，用於說明為何選擇該 tier/model。

範例（來自 `router.ts`）：

- `"policy=cost-optimize, complexity=trivial, skills=[conversation] -> gateway"`
- `"policy=cost-optimize, complexity=complex, skills=[analysis,coding] -> edge"`
- `"policy=cost-optimize, complexity=expert, skills=[reasoning] -> cloud"`
- `"skill-route: pattern=image-gen, forceTier=cloud, skills=[image-gen], Image generation requires cloud model with multimodal capabilities"`

用途：debug 和日誌記錄，會出現在 API response 的 `_hybrid_gateway.reason` 欄位以及檔案日誌中。

### 3.4 Heuristic Fallback（關鍵字兜底）

當分類器模型回傳的 **不是合法 JSON** 時（模型幻覺、timeout、格式亂掉），系統不會報錯，而是用純規則硬判（`heuristic.ts`）。

**第一步：字數判斷**

| user input 長度 | 判定 complexity | 路由目標 |
| --- | --- | --- |
| < 20 字 | `trivial` (0) | gateway |
| 20 ~ 99 字 | `simple` (1) | gateway |
| 100 ~ 499 字 | `moderate` (2) | gateway |
| >= 500 字 | `complex` (3) | edge |

**第二步：關鍵字加碼**

| 關鍵字 | 效果 |
| --- | --- |
| `code, function, class, import, export, def, const, let, var, async, await, return` | skill +coding，complexity 至少 moderate |
| `debug, error, bug, fix, crash, exception, traceback, stack trace` | skill +coding，complexity 直接升 complex |
| `architect, design, system, scale, infrastructure, microservice, distributed` | skill +analysis，complexity 直接升 complex |
| `translate, 翻譯, 翻译` | skill +translation，complexity 至少 simple |
| `搜尋, 搜索, search, lookup, find info` | skill +search，complexity 至少 simple |

這是最後防線，正常情況下模型會正確回 JSON，不會走到這裡。

### 3.5 Cache 機制

- 使用 **完全相同的 user input 字串** 做為 cache key（exact string match，非 hash）
- Cache 存放在記憶體內的 `Map`，Gateway 重啟後清空
- Cache TTL 預設 300 秒（5 分鐘），過期條目在下次 `get` 時惰性清除
- 命中 cache 時跳過模型呼叫，latencyMs ≈ 0
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

---

## 四、ROUTER（路由引擎）

Router 收到分類結果後，依 **兩階段** 決定路由：

```
分類結果 { complexity, skills }
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

**目前設定（`hybrid-gateway.json`）：只有一條 Skill Route — `image-gen` → 強制上雲。** 其餘 skill 一律走 Stage 2 的 Routing Policy。

設定位置：`hybrid-gateway.json` → `routing.skillRoutes`

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

| 欄位 | 說明 | 範例 |
| --- | --- | --- |
| `forceTier` | 強制走某個 tier，使用該 tier 的預設模型 | `"forceTier": "cloud"` → 對應 `defaults.cloud`（目前為 `cloud-gemini`） |
| `preferModel` | 強制走某個特定模型（跨 tier 也行） | `"preferModel": "cloud-gemini"` |

如果兩個都設了，`preferModel` 優先。

**注意：規則是從上到下掃描的，第一條命中就停止。**

### 4.2 Three-Tier Routing Policy（三層路由策略）

只有在**沒有任何 Skill Route 命中**時才進入 Policy 判斷。

v2 使用 **三層固定映射** 取代 v1 的 threshold 比較邏輯。Policy 仍然可設定，但 `cost-optimize` 的行為改為三層分流。

#### 四種 Policy 行為對照表（v2 三層版）

| 偵測到的 complexity | `edge-first` | `cloud-first` | `cost-optimize`（Default） | `quality-first` |
| --- | --- | --- | --- | --- |
| trivial (0) | **edge** | **cloud** | **gateway** | gateway |
| simple (1) | **edge** | **cloud** | **gateway** | gateway |
| moderate (2) | **edge** | **cloud** | **edge** | **edge** |
| complex (3) | **edge** | **cloud** | **cloud** | **cloud** |
| expert (4) | **edge** | **cloud** | **cloud** | **cloud** |

各 Policy 的設計思路（v2）：

| Policy | 思路 |
| --- | --- |
| `edge-first` | **最大化本地大模型**：一律走 edge（120B），不上雲，不走 gateway。 |
| `cloud-first` | **全走雲端**：一律 cloud。 |
| `cost-optimize` | **三層分流（預設）**：0–1 走 gateway（3B），2 走 edge（120B），3–4 走 cloud。兼顧效能與成本。 |
| `quality-first` | **品質優先**：0–1 走 gateway（3B），2–4 升級 edge / cloud（2 → edge，3–4 → cloud）。與 `cost-optimize` 行為相同，著重品質而非最省成本。 |

**你目前的設定（`hybrid-gateway.json`）：** `policy: "cost-optimize"` → 0–1 gateway，2 edge，3–4 cloud；**僅 `image-gen` 會被 Skill Route 強制上雲**，其餘依上表。

### 4.3 RoutingDecision 輸出範例

以下是各種 user input 經過分類 → 路由後的完整結果：

#### 範例 A：「你好」→ gateway (3B)

```
分類: complexity=trivial, skills=[conversation]
Skill Route: 無命中
Policy: cost-optimize, trivial(0) → gateway

RoutingDecision:
  model:    gateway-qwen2.5-3b
  tier:     gateway
  reason:   "policy=cost-optimize, complexity=trivial, skills=[conversation] -> gateway"
```

#### 範例 B：「幫我寫一個 Python 的 binary search」→ edge (120B)

```
分類: complexity=moderate, skills=[coding]
Skill Route: 無命中（目前只有 image-gen 有 Override）
Policy: cost-optimize, moderate(2) → edge

RoutingDecision:
  model:    edge-gpt-oss-120b
  tier:     edge
  reason:   "policy=cost-optimize, complexity=moderate, skills=[coding] -> edge"
```

#### 範例 C：「設計一個支援百萬用戶的微服務架構」→ edge (120B)

```
分類: complexity=complex, skills=[analysis, coding]
Skill Route: 無命中
Policy: cost-optimize, complex(3) → edge

RoutingDecision:
  model:    edge-gpt-oss-120b
  tier:     edge
  reason:   "policy=cost-optimize, complexity=complex, skills=[analysis,coding] -> edge"
```

#### 範例 D：「實作一個分散式共識算法並證明其正確性」→ cloud

```
分類: complexity=expert, skills=[coding, reasoning]
Skill Route: 無命中
Policy: cost-optimize, expert(4) → cloud

RoutingDecision:
  model:    cloud-gemini
  tier:     cloud
  reason:   "policy=cost-optimize, complexity=expert, skills=[coding,reasoning] -> cloud"
```

#### 範例 E：「幫我生成一張產品海報」→ cloud（Skill Route：image-gen）

```
分類: complexity=moderate, skills=[image-gen]
Skill Route: "image-gen" 命中 → forceTier=cloud → 直接走 cloud
Policy: 被跳過

RoutingDecision:
  model:    cloud-gemini
  tier:     cloud
  reason:   "skill-route: pattern=image-gen, ... Image generation requires cloud model with multimodal capabilities"
```

**注意：** 即使 complexity 未達 cloud 門檻，只要 Skill Route 命中（目前僅 `image-gen`）就會直接上雲。

#### 範例 F：Gateway 模型回應品質不足 → 可手動升級

```
使用者覺得 gateway (3B) 回應品質不夠
→ 可透過 /upgrade 指令或 retry 機制手動要求升級至 edge (120B)
→ 此為選配功能，不影響自動路由
```

---

## 五、Fallback（三層遞補）

v2 的 fallback 從雙向擴展為 **三層遞補鏈**，依嚴重程度逐級升級：

### 5.1 Fallback 遞補順序

| 原始 Tier | 第一 Fallback | 第二 Fallback | 全部失敗 |
| --- | --- | --- | --- |
| gateway (3B) 掛了 | → edge (120B) | → cloud | 回傳 502 錯誤 |
| edge (120B) 掛了 | → cloud | → gateway (3B) | 回傳 502 錯誤 |
| cloud 掛了 | → edge (120B) | → gateway (3B) | 回傳 502 錯誤 |

### 5.2 Fallback 邏輯說明

```
執行選定的 tier 模型
  │
  ├─ 成功 → 回傳結果
  │
  └─ 失敗 → 嘗試第一 Fallback
               │
               ├─ 成功 → 回傳結果（標記 fallbackUsed: true）
               │
               └─ 失敗 → 嘗試第二 Fallback
                            │
                            ├─ 成功 → 回傳結果（標記 fallbackUsed: true）
                            │
                            └─ 失敗 → 回傳 502 錯誤
```

**設計原則：**
- gateway 失敗 → 向上遞補（先 edge 再 cloud），確保有回應
- edge 失敗 → 先嘗試 cloud（能力更強），再退回 gateway
- cloud 失敗 → 先嘗試 edge（本地大模型），再退回 gateway（至少有回應）

可在設定關閉：`"fallbackEnabled": false`

---

## 六、API Response 中的路由資訊

每個 API response 都會附帶 `_hybrid_gateway` 欄位：

```json
{
  "id": "chatcmpl-1711100000000",
  "model": "gateway-qwen2.5-3b",
  "choices": [{ "message": { "role": "assistant", "content": "..." } }],
  "_hybrid_gateway": {
    "tier": "gateway",
    "complexity": "moderate",
    "reason": "policy=cost-optimize, complexity=moderate, skills=[coding] -> gateway",
    "classifyLatencyMs": 280,
    "fromCache": false,
    "fallbackUsed": false
  }
}
```

`tier` 的可能值（v2）：`"gateway"` | `"edge"` | `"cloud"`

---

## 七、設定檔結構（hybrid-gateway.json 對照）

以下為 v2 三層架構建議的設定檔結構：

```json
{
  "classifier": {
    "provider": "llamacpp",
    "model": "qwen2.5-3b",
    "endpoint": "http://127.0.0.1:13142",
    "cacheEnabled": true,
    "cacheTtlSeconds": 300
  },
  "models": {
    "gateway": {
      "provider": "llamacpp",
      "model": "qwen2.5-3b",
      "endpoint": "http://127.0.0.1:13142"
    },
    "edge": {
      "provider": "llamacpp",
      "model": "gpt-oss-120b",
      "endpoint": "http://127.0.0.1:13141"
    },
    "cloud": {
      "provider": "google",
      "model": "gemini-2.5-flash"
    }
  },
  "routing": {
    "policy": "cost-optimize",
    "skillRoutes": [
      {
        "skillPattern": "image-gen",
        "forceTier": "cloud",
        "reason": "Image generation requires cloud model with multimodal capabilities"
      }
    ]
  },
  "fallbackEnabled": true
}
```

**與 v1 的差異：**
- `models` 從 2 個 tier（edge / cloud）擴展為 3 個 tier（gateway / edge / cloud）
- `gateway` 模型與 `classifier` 共用同一端點和模型（qwen2.5-3b）
- 移除 `complexityThreshold`，改為三層固定映射邏輯
- `routing.defaults` 新增 `gateway` tier 的預設模型

---

## 八、效能與資源考量

### 8.1 三層分流的效益

| 指標 | v1（二層） | v2（三層） | 改善 |
| --- | --- | --- | --- |
| 簡單任務延遲 | 需等 120B 模型推論 | trivial/simple 由 3B 直接回應 | **大幅降低**（3B 推論速度快數倍） |
| 120B 負載 | 所有 complexity 0–2 都走 120B | 僅 complexity 2 走 120B（3 以上走 cloud） | **顯著減少**（大量 trivial/simple 流量改走 3B） |
| Cloud API 成本 | complexity 3–4 都上雲 | 僅 complexity 3–4 上雲（moderate 由 edge 承擔） | **維持可控**（moderate 本地處理，不增加雲端費用） |
| 3B 模型利用率 | 僅做分類 | 分類 + 執行 trivial/simple | **提高硬體利用率** |

### 8.2 適用情境

- **complexity 0–1（trivial / simple，約佔 40–50% 的日常使用）**：打招呼、簡單問答、短翻譯等，3B 模型足以勝任，延遲最低
- **complexity 2（moderate，約佔 30–40%）**：多步驟指令、程式片段、摘要、日常工作任務等，走 edge 120B 提供更高品質回應
- **complexity 3–4（complex / expert，約佔 10–20%）**：系統架構、深度分析、前沿研究等，直接上雲取得最強模型能力
