#requires -Version 5.1
<#
  One-shot setup for DBSchemaCheck prerequisites (Windows / PowerShell).

  1. Copy scripts/.env.setup.example to scripts/.env.setup and fill in YOUR values.
     (scripts/.env.setup is gitignored. ANTHROPIC_API_KEY is intentionally NOT handled
      here -- set it yourself, see README.)
  2. Run:  powershell -ExecutionPolicy Bypass -File scripts/setup.ps1

  Secret values flow from scripts/.env.setup into GitHub Secrets and Supabase secrets only;
  this script never prints them. It pushes secrets via temp dotenv files (no values on the
  command line).

  Prereqs on your machine: gh (authenticated), supabase CLI, and optionally psql (for schema).
#>
[CmdletBinding()]
param(
  [string]$Repo = "Chao-Shiun/DBSchemaCheck",
  [string]$EnvFile = "$PSScriptRoot/.env.setup"
)
$ErrorActionPreference = "Stop"

function Assert-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Required command '$name' not found on PATH." }
}

if (-not (Test-Path $EnvFile)) {
  throw "Missing $EnvFile. Copy scripts/.env.setup.example to scripts/.env.setup and fill in your values."
}

# Parse KEY=VALUE lines (ignores blanks and # comments).
$vars = @{}
foreach ($line in Get-Content $EnvFile) {
  $t = $line.Trim()
  if (-not $t -or $t.StartsWith("#") -or -not $t.Contains("=")) { continue }
  $idx = $t.IndexOf("=")
  $vars[$t.Substring(0, $idx).Trim()] = $t.Substring($idx + 1).Trim()
}
function Need($name) {
  if (-not $vars.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($vars[$name])) { throw "Missing '$name' in $EnvFile" }
}

Assert-Command gh

Write-Host "== Pushing GitHub Actions secrets =="
$ghSecrets = @("SLACK_BOT_TOKEN", "SLACK_CHANNEL_ID", "SUPABASE_DB_HOST", "SUPABASE_DB_PORT", "SUPABASE_DB_NAME", "SUPABASE_DB_USER", "SUPABASE_DB_PASSWORD")
$ghTmp = New-TemporaryFile
try {
  $lines = foreach ($s in $ghSecrets) { Need $s; "$s=$($vars[$s])" }
  Set-Content -Path $ghTmp -Encoding utf8 -Value $lines
  gh secret set --env-file $ghTmp --repo $Repo
  Write-Host "  set: $($ghSecrets -join ', ')"
} finally { Remove-Item $ghTmp -Force -ErrorAction SilentlyContinue }

Write-Host "== Supabase: link, schema, function, secrets =="
Need "SUPABASE_PROJECT_REF"; Need "SLACK_SIGNING_SECRET"; Need "GH_DISPATCH_TOKEN"
Assert-Command supabase

supabase link --project-ref $vars["SUPABASE_PROJECT_REF"]

if ($vars.ContainsKey("SUPABASE_DB_URL") -and $vars["SUPABASE_DB_URL"]) {
  if (Get-Command psql -ErrorAction SilentlyContinue) {
    Write-Host "  applying db/schema.sql via psql"
    psql $vars["SUPABASE_DB_URL"] -v ON_ERROR_STOP=1 -f "db/schema.sql"
  } else {
    Write-Warning "  psql not found -- apply db/schema.sql manually in the Supabase SQL editor."
  }
}

Write-Host "  deploying Edge Function slack-approval (--no-verify-jwt)"
supabase functions deploy slack-approval --no-verify-jwt --project-ref $vars["SUPABASE_PROJECT_REF"]

# Push the two function secrets via a temp dotenv file (no values on the command line).
$fnTmp = New-TemporaryFile
try {
  Set-Content -Path $fnTmp -Encoding utf8 -Value @(
    "SLACK_SIGNING_SECRET=$($vars['SLACK_SIGNING_SECRET'])",
    "GH_DISPATCH_TOKEN=$($vars['GH_DISPATCH_TOKEN'])"
  )
  supabase secrets set --env-file $fnTmp --project-ref $vars["SUPABASE_PROJECT_REF"]
} finally { Remove-Item $fnTmp -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "Done. Remaining manual steps you must do yourself:"
Write-Host "  1) Set ANTHROPIC_API_KEY  ->  gh secret set ANTHROPIC_API_KEY --repo $Repo   (or GitHub UI; see README)"
Write-Host "  2) Slack: set the Interactivity Request URL to your real function URL, Install to Workspace,"
Write-Host "     then run '/invite @dbschemacheck-gate' in your target Slack channel (SLACK_CHANNEL_ID)."
