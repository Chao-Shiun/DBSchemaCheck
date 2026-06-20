#requires -Version 5.1
<#
  One-shot setup for DBSchemaCheck prerequisites (Windows / PowerShell).

  1. Copy scripts/.env.setup.example to scripts/.env.setup and fill in YOUR values.
     scripts/.env.setup is gitignored. Claude auth is configured in the CI provider.
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

if (Get-Command gh -ErrorAction SilentlyContinue) {
  Write-Host "== Pushing GitHub Actions secrets =="
  $ghSecrets = @("SLACK_BOT_TOKEN", "SLACK_CHANNEL_ID", "SUPABASE_DB_HOST", "SUPABASE_DB_PORT", "SUPABASE_DB_NAME", "SUPABASE_DB_USER", "SUPABASE_DB_PASSWORD")
  $ghTmp = New-TemporaryFile
  try {
    $lines = foreach ($s in $ghSecrets) { Need $s; "$s=$($vars[$s])" }
    # Write UTF-8 WITHOUT BOM; gh's dotenv parser rejects a leading BOM.
    [System.IO.File]::WriteAllText($ghTmp.FullName, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    gh secret set --env-file $ghTmp.FullName --repo $Repo
    Write-Host "  set: $($ghSecrets -join ', ')"
  } finally { Remove-Item $ghTmp -Force -ErrorAction SilentlyContinue }
} else {
  Write-Warning "gh not found -- skipping GitHub Actions secrets. Configure GitHub or Bitbucket repository variables manually."
}

Write-Host "== Supabase: link, schema, function, secrets =="
Need "SUPABASE_PROJECT_REF"; Need "SLACK_SIGNING_SECRET"
Assert-Command supabase

if ($vars.ContainsKey("SUPABASE_DB_URL") -and $vars["SUPABASE_DB_URL"]) {
  if (Get-Command psql -ErrorAction SilentlyContinue) {
    Write-Host "  applying db/schema.sql via psql"
    psql $vars["SUPABASE_DB_URL"] -v ON_ERROR_STOP=1 -f "db/schema.sql"
  } else {
    Write-Warning "  psql not found -- apply db/schema.sql manually in the Supabase SQL editor."
  }
}

Write-Host "  deploying Edge Function slack-approval (--use-api, --no-verify-jwt)"
# --use-api bundles server-side (no Docker / no edge-runtime image pull).
supabase functions deploy slack-approval --use-api --no-verify-jwt --project-ref $vars["SUPABASE_PROJECT_REF"]

# Push function secrets via a temp dotenv file (no values on the command line).
$fnTmp = New-TemporaryFile
try {
  $fnLines = @("SLACK_SIGNING_SECRET=$($vars['SLACK_SIGNING_SECRET'])")
  foreach ($optionalSecret in @("GH_DISPATCH_TOKEN", "BITBUCKET_API_USERNAME", "BITBUCKET_API_TOKEN", "APPROVER_SLACK_IDS")) {
    if ($vars.ContainsKey($optionalSecret) -and -not [string]::IsNullOrWhiteSpace($vars[$optionalSecret])) {
      $fnLines += "$optionalSecret=$($vars[$optionalSecret])"
    }
  }
  # Write UTF-8 WITHOUT BOM (Supabase/gh dotenv parsers reject a leading BOM).
  [System.IO.File]::WriteAllText($fnTmp.FullName, (($fnLines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  supabase secrets set --env-file $fnTmp.FullName --project-ref $vars["SUPABASE_PROJECT_REF"]
} finally { Remove-Item $fnTmp -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "Done. Remaining manual steps you must do yourself:"
Write-Host "  1) GitHub: set CLAUDE_CODE_OAUTH_TOKEN in Actions secrets if you use GitHub Actions."
Write-Host "  2) Bitbucket: set repository variables listed in README if you use Bitbucket Pipelines."
Write-Host "  3) Slack: set the Interactivity Request URL to your real function URL, Install to Workspace,"
Write-Host "     then run '/invite @dbschemacheck-gate' in your target Slack channel (SLACK_CHANNEL_ID)."
