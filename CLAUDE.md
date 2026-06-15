# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

DBSchemaCheck is **not a typical application** — it is a CI-stage guardrail. On a Pull Request to `master`, a GitHub Actions workflow runs Claude (via `claude-code-action`), which uses Google's **MCP Toolbox for Databases** to read the **live Supabase Postgres schema**, compares it against the PR's code diff, and blocks the merge when the code references the schema incorrectly or unsafely. Results are always reported to Slack; warnings can be approved or rejected from Slack via a Supabase Edge Function.

There is no application server and no automated test suite. The "code" is the pipeline itself, spread across the components below. The way to exercise it end-to-end is to open a PR (see `demo/DEMO.md`).

## Architecture (the big picture)

Single-run control flow:
`PR → review job → Claude reads diff + live schema → verdict.json → schema-gate commit status → Slack → (warning only) Edge Function → repository_dispatch → resume job updates schema-gate`.

How the pieces connect:
- **`.github/workflows/schema-review.yml`** — the orchestrator. The `review` job (on `pull_request`) downloads the toolbox, runs `claude-code-action`, then computes status from `verdict.json` with `jq`, sets the `schema-gate` commit status, posts to Slack, and `exit 1`s on error. The `resume` job (on `repository_dispatch: schema-approval`) runs the post-approval deploy step.
- **`ci/review-prompt.md`** — the AI reviewer's instructions: WHAT to check, the errors-vs-warnings classification policy, and the required `verdict.json` shape. **Edit this file to change what gets flagged or how severity is graded.**
- **`ci/mcp-config.json`** — declares the `toolbox` MCP server (stdio, `--prebuilt postgres`). The toolbox reads `POSTGRES_*` from the job environment.
- **`ci/notify-slack.sh`** — builds the Block Kit message from `verdict.json` and posts via `chat.postMessage` (always). Adds approve/reject buttons on warnings.
- **`supabase/functions/slack-approval/index.ts`** — Deno Edge Function. Verifies the Slack signature, ACKs within 3s, then triggers `repository_dispatch`; the `resume` job updates the `schema-gate` commit status with `GITHUB_TOKEN`.
- **`db/schema.sql`** — the payment-feature schema applied to Supabase. NOTE: the reviewer reads the **live** schema via the toolbox, not this file; `schema.sql` only sets up the database.
- **`src/PaymentDemo/`** — a small .NET sample whose DB-access code is what gets reviewed in the demo.
- **`scripts/setup.ps1`** — one-shot provisioner: pushes GitHub secrets and deploys the Edge Function from a local `scripts/.env.setup` (gitignored).

**Key concept — the gate is one commit status.** `schema-gate` is the single source of truth for whether a PR may merge. It is set by the workflow from Claude's verdict, then updated by the `resume` job after a human Slack decision. It must be configured as a required status check on `master` to actually block merges.

**Severity model (set in `ci/review-prompt.md`, enforced in the workflow):** `errors` (would cause a runtime failure, or SQL injection) → `schema-gate=failure`, block. `warnings` (no error but a performance/truncation risk, e.g. missing index, over-length column) → `schema-gate=pending`, wait for Slack approval. neither → `pass`.

## Commands

```bash
# Build the .NET sample
dotnet build src/PaymentDemo/PaymentDemo.csproj

# Run the sample against a database (needs a connection string)
SUPABASE_DB_CONNECTION="postgresql://USER:PWD@HOST:5432/postgres?sslmode=require" dotnet run --project src/PaymentDemo

# Syntax-check the Slack notifier (it uses jq to assemble the Block Kit payload)
bash -n ci/notify-slack.sh

# Deploy the Edge Function (server-side bundle; no Docker; JWT off for Slack)
supabase functions deploy slack-approval --use-api --no-verify-jwt --project-ref <project-ref>

# Provision GitHub + Supabase from a filled scripts/.env.setup (Windows / PowerShell)
powershell -ExecutionPolicy Bypass -File scripts/setup.ps1
```

There is no test runner. Validate changes by opening a PR per `demo/DEMO.md` and watching the `DB Schema Check` workflow (ERROR blocks, PASS passes, WARNING posts Slack buttons).

## Environment-specific gotchas (each of these has bitten this project)

- **The DB connection must use the Session pooler, not the direct host.** GitHub Actions runners are IPv4-only; Supabase's `db.<ref>.supabase.co` is IPv6-only. Set the `SUPABASE_DB_HOST` / `SUPABASE_DB_USER` secrets to the pooler (`aws-N-<region>.pooler.supabase.com`, user `postgres.<ref>`, port 5432).
- **`claude-code-action` needs `id-token: write`** in the workflow `permissions` (and/or an explicit `github_token: ${{ github.token }}`), or it aborts at the OIDC step before reviewing.
- **`supabase functions deploy` must use `--use-api`** (server-side bundling) to avoid pulling the edge-runtime Docker image, plus `--no-verify-jwt` because Slack sends no Supabase JWT.
- **PowerShell `Set-Content -Encoding utf8` writes a UTF-8 BOM** that the `gh`/`supabase --env-file` dotenv parsers reject. Write temp dotenv files with `[System.IO.File]::WriteAllText(path, text, (New-Object System.Text.UTF8Encoding $false))`.
- **This repo is public — never commit internal identifiers.** The Slack channel ID and Supabase project ref live in GitHub secrets, not source. `scripts/.env.setup` (holding all credentials) is gitignored.

## SQL / DB conventions

This project targets **PostgreSQL (Supabase)**. SQL must be parameterized — the demo deliberately uses string interpolation as the "bad" example the reviewer flags as SQL injection. Do not use MSSQL-only syntax such as `WITH (NOLOCK)`.
