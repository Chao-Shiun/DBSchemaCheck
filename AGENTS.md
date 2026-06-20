# Repository Guidelines

## Project Structure & Module Organization

This repository demonstrates CI-stage schema drift checks for a .NET payment sample backed by Supabase PostgreSQL.

- `.github/workflows/schema-review.yml` defines the GitHub pull request schema gate and Slack notification flow.
- `bitbucket-pipelines.yml` defines the Bitbucket reviewer-triggered schema gate.
- `src/PaymentDemo/` contains the .NET 8 console sample using Npgsql and Dapper.
- `db/schema.sql` is the source-of-truth PostgreSQL schema; `db/seed.sql` holds sample data.
- `ci/` contains the AI review prompt, MCP toolbox config, Slack notification script, and Bitbucket review helpers.
- `supabase/functions/slack-approval/` contains the Deno Edge Function for Slack callbacks.
- `scripts/setup.ps1` provisions GitHub/Supabase secrets and deploys the Edge Function.
- `demo/DEMO.md` documents PASS, WARNING, and ERROR scenarios.

## Build, Test, and Development Commands

- `dotnet restore src/PaymentDemo/PaymentDemo.csproj` restores .NET dependencies.
- `dotnet build src/PaymentDemo/PaymentDemo.csproj` compiles the payment demo.
- `$env:SUPABASE_DB_CONNECTION="postgresql://USER:PASSWORD@HOST:5432/postgres?sslmode=require"; dotnet run --project src/PaymentDemo` runs the demo against Supabase.
- `psql "postgresql://USER:PASSWORD@HOST:5432/postgres?sslmode=require" -f db/schema.sql` applies the schema manually.
- `powershell -ExecutionPolicy Bypass -File scripts/setup.ps1` pushes secrets and deploys `slack-approval`.
- `supabase functions serve slack-approval` runs the Edge Function locally.

## Coding Style & Naming Conventions

Use C# 12/.NET 8 conventions with nullable reference types enabled. Prefer sealed classes or records for small immutable models, PascalCase public members, camelCase locals and parameters, and `_camelCase` private fields. Use string interpolation instead of `+` concatenation. Keep method parameter lists on one line when practical, and do not add `#region` blocks. All new code comments must be in English.

SQL in `src/PaymentDemo` must be PostgreSQL-compatible, parameterized through Dapper, and kept in sync with `db/schema.sql`.

## Testing Guidelines

No automated test project or coverage threshold is currently configured. Before opening a PR, run `dotnet build src/PaymentDemo/PaymentDemo.csproj` and exercise relevant demo paths when changing SQL, schema, or repository code. If tests are added, place them under `tests/` and document the `dotnet test` command here.

## Commit & Pull Request Guidelines

Recent commits use Conventional Commits such as `feat:` and `fix:`. Keep messages in English and describe only the code change. Pull requests should target `master`, explain schema-impacting changes, reference issues when available, and include local build or CI evidence. Do not commit local IDE folders, `scripts/.env.setup`, `verdict.json`, `pr.diff`, `toolbox`, or secrets.

## Security & Configuration Tips

Treat GitHub Actions secrets, Bitbucket repository variables, Supabase secrets, Slack tokens, and database URLs as sensitive. Keep runtime configuration in CI/Supabase secret stores or ignored local files. The schema gate uses live PostgreSQL metadata, so verify table names, columns, constraints, and indexes before changing data access code.
