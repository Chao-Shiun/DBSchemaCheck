# DBSchemaCheck

> CI 階段的 **AI Schema 漂移防護**：在程式碼合併進 `master` 之前，用 Claude 透過
> [MCP Toolbox for Databases](https://github.com/googleapis/genai-toolbox) 取得 Supabase
> 的**實際 schema**，深入比對本次 PR 的程式碼異動，攔下會出錯或有風險的變更，並把結果
> 通知 Slack。警告級問題可在 Slack 上即時「放行 / 拒絕」。

## 它解決什麼問題

程式碼裡對 DB 的操作（SQL、欄位、資料表、約束值）可能與資料庫實際 schema 不一致，這類
不符往往要到執行期才爆出錯誤。本專案在 **合併前** 就抓出來，避免被佈署。

## 嚴重度與處置

| 類別 | 定義 | 處置 |
|---|---|---|
| **ERROR** | 任何會導致執行期錯誤的問題（缺/改名欄位、型別不符、違反 NOT NULL / CHECK、外鍵不符），以及 **SQL Injection** | `schema-gate` = failure、CI 失敗、Slack 發 **FAILED**（含完整問題與修正建議）→ 阻擋合併 |
| **WARNING** | 不會出錯但有效能或資料風險（缺索引、欄位長度不符導致截斷、`SELECT *`、N+1） | `schema-gate` = pending、Slack 發 **WARNING + 放行/拒絕按鈕** → 由人工決策 |
| **PASS** | 無問題 | `schema-gate` = success、Slack 發 **SUCCESS** → 允許合併 |

Slack 訊息一律包含：**狀態、專案名稱、git tag、PR 編號、commit SHA**；錯誤/警告附完整說明。

## 架構流程

```
PR → master
  └─ GitHub Actions（review job）
       ├─ 下載 mcp-toolbox binary
       ├─ claude-code-action 跑 Claude
       │     └─ Claude 讀 pr.diff → 經 toolbox(stdio,--prebuilt postgres) 讀 Supabase 實際 schema → 寫 verdict.json
       ├─ 由 verdict.json 計算狀態 → 設定 schema-gate commit status
       └─ 一律發 Slack 通知

WARNING 時：
  Slack 放行/拒絕按鈕 → Supabase Edge Function（驗 Slack 簽章）
       └─ repository_dispatch(decision) → resume job 更新 schema-gate 並執行後續流程
```

## 專案結構

```
.github/workflows/schema-review.yml   # pull_request + repository_dispatch；review / resume 兩 job
db/schema.sql                         # 支付 schema（真實來源）
db/seed.sql                           # 選用種子資料
src/PaymentDemo/                      # .NET 範例（Npgsql + Dapper），master 上為乾淨基準
ci/review-prompt.md                   # 給 Claude 的審查指示與輸出格式
ci/mcp-config.json                    # toolbox stdio MCP 設定
ci/notify-slack.sh                    # 由 verdict.json 組 Block Kit 並發 chat.postMessage
slack/manifest.yml                    # Slack App Manifest（已驗證，照貼即可建立 app）
supabase/functions/slack-approval/    # Edge Function：驗章 → dispatch；resume job 設 commit status
scripts/setup.ps1                     # 一鍵推送 GitHub/Supabase secrets + 部署 Edge Function
scripts/.env.setup.example            # 設定值範本（複製成 .env.setup 後填寫）
demo/DEMO.md                          # 如何觸發 ERROR / WARNING / PASS 三種路徑
```

---

## 前置作業

設定分成兩類：

- 🟦 **只有你能做**（建立帳號/app、授權、產生並取得憑證）—— 我在規範上不能代你登入帳號、建立 app 或處理憑證。
- 🟩 **腳本幫你做掉**（把憑證推進 GitHub/Supabase、部署 Edge Function）—— 你只要把值填進 `scripts/.env.setup` 再跑 `scripts/setup.ps1`，憑證不經過第三方。

### 步驟 1（你做）：建立帳號與服務，取得憑證
1. **Supabase**：建立專案，記下 project ref、DB host/密碼。建議另建一個**唯讀角色**給 CI/toolbox 連線。
2. **Slack app**：到 https://api.slack.com/apps?new_app=1 →「Create New App」→「From a manifest」→ 選工作區 → 貼上 [slack/manifest.yml](slack/manifest.yml) 的內容（**先把裡面的 `YOUR-PROJECT-REF` 換成你的 Supabase project ref**）→ 建立。
   - manifest 已設定好：bot 名稱、scope `chat:write`、Interactivity 開啟。
3. **取得憑證**：
   - Slack →「OAuth & Permissions」→ Install to Workspace → 複製 **Bot User OAuth Token（`xoxb-`）**。
   - Slack →「Basic Information」→ App Credentials → 複製 **Signing Secret**。
   - GitHub → 產生一個**細粒度 PAT（`GH_DISPATCH_TOKEN`）**，最小權限：Repository access 選此 repo，Contents 設為 Read and write（給 Edge Function 觸發 `repository_dispatch` 用）。

### 步驟 2（你做）：填寫設定值
複製範本並填入你剛取得的值：
```powershell
Copy-Item scripts/.env.setup.example scripts/.env.setup
notepad scripts/.env.setup   # 填入 SLACK_BOT_TOKEN / SUPABASE_* / SLACK_SIGNING_SECRET / GH_DISPATCH_TOKEN
```
> `scripts/.env.setup` 已被 gitignore，不會上傳。

### 步驟 3（腳本做）：一鍵推送 secrets + 部署 Edge Function
```powershell
powershell -ExecutionPolicy Bypass -File scripts/setup.ps1
```
腳本會：把 GitHub Actions secrets 推到 repo、`supabase link`、套用 `db/schema.sql`、`supabase functions deploy slack-approval --no-verify-jwt`、設定 Edge Function 的 `SLACK_SIGNING_SECRET` 與 `GH_DISPATCH_TOKEN`。
> 需先安裝並登入 `gh`、安裝 `supabase` CLI；`psql` 可選（沒有就到 Supabase SQL editor 手動貼 `db/schema.sql`）。

### 步驟 4（你做）：填入 ANTHROPIC_API_KEY ⭐
這把金鑰刻意保留給你自己填。兩種方式擇一：
- **指令**：`gh secret set ANTHROPIC_API_KEY --repo Chao-Shiun/DBSchemaCheck`（執行後貼上金鑰值，不會顯示在畫面）。
- **GitHub 網頁**：repo →「**Settings → Secrets and variables → Actions → New repository secret**」→ Name 填 `ANTHROPIC_API_KEY`、Secret 填金鑰 → Add secret。
  直達連結：`https://github.com/Chao-Shiun/DBSchemaCheck/settings/secrets/actions/new`

### 步驟 5（你做）：完成 Slack 串接
1. Slack app →「Interactivity & Shortcuts」→ 確認 Request URL 為你真正的 Edge Function 網址：
   `https://<project-ref>.functions.supabase.co/slack-approval`（部署後才會存在；步驟 3 已部署）。
2. 在你的目標 Slack 頻道（即 `SLACK_CHANNEL_ID` 對應的頻道）輸入 `/invite @dbschemacheck-gate` 把 bot 加進頻道（否則 `chat.postMessage` 會回 `not_in_channel`）。

### 分支保護（注意：免費方案 + 私有 repo 無法自動開啟）
理想上要把 `schema-gate` 設為 `master` 的**必要狀態檢查**，但 GitHub 對**私有 repo 的分支保護/ruleset 需要 GitHub Pro 或將 repo 設為公開**（我嘗試以 API 設定時回 HTTP 403）。三個選項：
- 升級 GitHub Pro，或
- 將此 repo 改為公開（注意會公開內部頻道 ID），或
- 暫不開啟硬性 enforcement：ERROR 仍會讓 workflow `exit 1`，PR 的「DB Schema Check」會顯示**紅色失敗**可供把關；WARNING 的 pending 狀態仍會設定，只是不會「硬性擋住」merge。

---

## 跑 Demo

詳見 [demo/DEMO.md](demo/DEMO.md)。摘要：
- **ERROR**：在功能分支加入引用 `card_last4` / 寫入 `status='PAID'` / 字串插補拼 SQL 的方法 → 開 PR → CI 失敗、Slack FAILED。
- **WARNING**：加入過濾 `payments.status`（無索引）/ 寫入過長 `note` 的方法 → 開 PR → Slack WARNING + 按鈕 → 點放行/拒絕。
- **PASS**：不引入問題 → Slack SUCCESS、綠燈。

### 本機建置與探索
```bash
dotnet build src/PaymentDemo            # 編譯範例
SUPABASE_DB_CONNECTION="postgresql://USER:PASSWORD@HOST:5432/postgres?sslmode=require" \
  dotnet run --project src/PaymentDemo  # 連實際 DB 跑一次
supabase functions serve slack-approval # 本機測試 Edge Function
```

---

## 安全注意事項
- 所有憑證走 GitHub Secrets / Supabase secrets，**不硬編碼、不 commit**。`scripts/.env.setup` 已被 gitignore。
- Edge Function **必驗 Slack 簽章**（含 timestamp 防重放），並在 3 秒內回 200（其餘工作用 `EdgeRuntime.waitUntil` 背景處理）；建議用 `APPROVER_SLACK_IDS` 限制核准者。
- toolbox 連線建議用**唯讀角色**；`--allowedTools` 僅放行內省類工具。
- 本專案使用 **PostgreSQL**，SQL 一律**參數化**（demo 以字串插補反例示範注入偵測）；不使用 MSSQL 的 `WITH (NOLOCK)`。

## 已釘住的版本與待確認點
- mcp-toolbox：`v1.4.0`，prebuilt postgres 環境變數 `POSTGRES_HOST/PORT/DATABASE/USER/PASSWORD/QUERY_PARAMS`，工具含 `list_tables / list_indexes / list_views / execute_sql / get_query_plan`（來源：官方 repo）。
- claude-code-action：`@v1`，輸入 `anthropic_api_key / prompt / claude_args`（來源：官方 action.yml）。
- Slack manifest 欄位與 `chat:write` 最小 scope 已對照 docs.slack.dev/reference/app-manifest 驗證。
