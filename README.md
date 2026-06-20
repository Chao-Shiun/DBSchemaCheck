# DBSchemaCheck

DBSchemaCheck 示範在 PR 階段用 AI 檢查 .NET 程式碼與 Supabase PostgreSQL schema 是否一致。CI 會把 PR diff、live database metadata、索引與查詢計畫交給 Claude review，產出 `verdict.json`，再依結果更新 GitHub status 或 Bitbucket reviewer 決策，並把結果送到 Slack。

## Gate 行為

| 結果 | 條件 | Gate 行為 |
|---|---|---|
| **ERROR** | 會造成執行期錯誤或安全風險，例如缺欄位、型別不符、違反 `NOT NULL` / `CHECK` / FK、SQL injection | GitHub 設 `schema-gate=failure`；Bitbucket 由 bot reviewer request changes，pipeline 失敗 |
| **WARNING** | 不會直接出錯，但有具體效能或資料風險，例如缺少必要索引、可能截斷、`SELECT *`、N+1 | 送 Slack approval。GitHub 維持 pending；Bitbucket 先由 bot reviewer request changes，等 Slack approve/reject 後改成 approve/request changes |
| **PASS** | 沒有 schema 問題 | GitHub 設 `schema-gate=success`；Bitbucket 由 bot reviewer approve |

## GitHub 流程

```text
PR to master
  -> GitHub Actions schema-review.yml
      -> download MCP Toolbox
      -> Claude reviews pr.diff against live Supabase schema
      -> write verdict.json
      -> set schema-gate status
      -> post Slack result

WARNING
  -> Slack button
      -> Supabase Edge Function verifies Slack signature
      -> repository_dispatch
      -> resume job updates schema-gate to success or failure
```

## Bitbucket 流程

```text
PR to main
  -> Bitbucket Pipelines bitbucket-pipelines.yml
      -> ci/bitbucket-schema-review.sh
      -> skip unless the configured DB-check reviewer is selected
      -> run Claude schema review against live Supabase schema
      -> ci/bitbucket-review-decision.sh applies the bot reviewer decision
      -> post Slack result

WARNING
  -> bot reviewer requests changes first
  -> Slack approve/reject
      -> Supabase Edge Function verifies Slack signature
      -> approve clears request-changes and approves the PR
      -> reject keeps or reapplies request-changes
```

The selectable reviewer is controlled by repository variables. Configure one or more of:

- `DB_CHECK_REVIEWER_UUID`
- `DB_CHECK_REVIEWER_ACCOUNT_ID`
- `DB_CHECK_REVIEWER_NICKNAME`
- `DB_CHECK_REVIEWER_DISPLAY_NAME`

Values can be comma-separated. If none are configured, the Bitbucket pipeline exits without running the DB check.

## Project Structure

```text
.github/workflows/schema-review.yml   GitHub PR schema gate and Slack resume flow
bitbucket-pipelines.yml               Bitbucket PR pipeline entry point
ci/bitbucket-schema-review.sh          Reviewer-triggered Bitbucket schema review
ci/bitbucket-review-decision.sh        Bitbucket approve/request-changes helper
ci/review-prompt.md                    Claude schema-review instructions
ci/mcp-config.json                     MCP Toolbox stdio config
ci/notify-slack.sh                     Slack Block Kit notification script
db/schema.sql                          PostgreSQL source-of-truth schema
db/seed.sql                            Demo data
src/PaymentDemo/                       .NET 8 sample using Npgsql and Dapper
supabase/functions/slack-approval/     Slack approval Edge Function
scripts/setup.ps1                      GitHub/Supabase setup helper
scripts/.env.setup.example             Local setup template, copied to ignored .env.setup
demo/DEMO.md                           PASS, WARNING, and ERROR demo cases
```

## GitHub Setup

1. Copy the template and fill in local secrets:

```powershell
Copy-Item scripts/.env.setup.example scripts/.env.setup
notepad scripts/.env.setup
```

2. Run the setup helper:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/setup.ps1
```

The script pushes GitHub Actions secrets, optionally applies `db/schema.sql`, deploys `slack-approval`, and sets Supabase function secrets. `CLAUDE_CODE_OAUTH_TOKEN` is set separately in GitHub Actions secrets because it should not be stored in the local setup file.

3. Slack app:

- Create an app from `slack/manifest.yml`.
- Set Interactivity Request URL to `https://<project-ref>.functions.supabase.co/slack-approval`.
- Install the app to the workspace.
- Invite the bot to the target channel with `/invite @dbschemacheck-gate`.

## Bitbucket Setup

Enable Bitbucket Pipelines, then add these repository variables:

| Variable | Purpose |
|---|---|
| `BITBUCKET_API_USERNAME` | Username for the bot reviewer account |
| `BITBUCKET_API_TOKEN` | Secured app password/API token for that account |
| `DB_CHECK_REVIEWER_UUID` or another selector | Identifies the reviewer that turns on DB checking |
| `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DATABASE`, `POSTGRES_USER`, `POSTGRES_PASSWORD` | Live Supabase PostgreSQL metadata connection |
| `POSTGRES_QUERY_PARAMS` | Optional, defaults to `sslmode=require` |
| `ANTHROPIC_API_KEY` | Used by Claude Code CLI in Bitbucket Pipelines |
| `SLACK_BOT_TOKEN`, `SLACK_CHANNEL_ID` | Optional for pass/error; required for warning approval |

For Slack approval on Bitbucket, also set these Supabase function secrets:

```powershell
supabase secrets set BITBUCKET_API_USERNAME=<bot-username> BITBUCKET_API_TOKEN=<bot-token> --project-ref <project-ref>
```

Optional approval restriction:

```powershell
supabase secrets set APPROVER_SLACK_IDS=U0123456789,U9876543210 --project-ref <project-ref>
```

## Local Verification

```powershell
dotnet build src/PaymentDemo/PaymentDemo.csproj
$env:SUPABASE_DB_CONNECTION="postgresql://USER:PASSWORD@HOST:5432/postgres?sslmode=require"; dotnet run --project src/PaymentDemo
supabase functions serve slack-approval
```

## Demo

See [demo/DEMO.md](demo/DEMO.md) for sample PASS, WARNING, and ERROR changes.

## Security Notes

- Do not commit `scripts/.env.setup`, `verdict.json`, `pr.diff`, `toolbox`, tokens, or database URLs.
- Slack requests are verified with signing secret and timestamp replay protection.
- The schema review uses live PostgreSQL metadata, so keep `db/schema.sql` and Supabase aligned before relying on CI results.
- The Bitbucket bot account should be a reviewer account with permission to approve and request changes on PRs.
