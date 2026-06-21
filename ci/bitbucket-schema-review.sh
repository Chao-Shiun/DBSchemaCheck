#!/usr/bin/env bash
# Runs the schema review only when the configured DB-check reviewer is selected on the PR.
set -euo pipefail

CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-8}"

: "${BITBUCKET_PR_ID:?BITBUCKET_PR_ID is required; this script runs only for pull requests}"
: "${BITBUCKET_WORKSPACE:?BITBUCKET_WORKSPACE is required}"
: "${BITBUCKET_REPO_SLUG:?BITBUCKET_REPO_SLUG is required}"
: "${BITBUCKET_BRANCH:?BITBUCKET_BRANCH is required}"
: "${BITBUCKET_COMMIT:?BITBUCKET_COMMIT is required}"
: "${BITBUCKET_PR_DESTINATION_BRANCH:?BITBUCKET_PR_DESTINATION_BRANCH is required}"
DB_CHECK_REVIEWER_WAIT_ATTEMPTS="${DB_CHECK_REVIEWER_WAIT_ATTEMPTS:-6}"
DB_CHECK_REVIEWER_WAIT_SECONDS="${DB_CHECK_REVIEWER_WAIT_SECONDS:-10}"
selector_configured=false
for selector in DB_CHECK_REVIEWER_UUID DB_CHECK_REVIEWER_ACCOUNT_ID DB_CHECK_REVIEWER_NICKNAME DB_CHECK_REVIEWER_DISPLAY_NAME; do
  if [ -n "${!selector:-}" ]; then
    selector_configured=true
  fi
done

if [ "$selector_configured" != "true" ]; then
  echo "No DB-check reviewer selector is configured; skipping schema review."
  exit 0
fi

: "${BITBUCKET_API_USERNAME:?BITBUCKET_API_USERNAME is required}"
: "${BITBUCKET_API_TOKEN:?BITBUCKET_API_TOKEN is required}"

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git jq postgresql-client

matches_csv() {
  local candidate="${1:?candidate required}"
  local csv="${2:-}"
  local item
  local -a items
  IFS="," read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    item="$(printf '%s' "$item" | xargs)"
    if [ -n "$item" ] && [ "$candidate" = "$item" ]; then
      return 0
    fi
  done
  return 1
}

is_positive_integer() {
  printf '%s' "${1:-}" | grep -Eq '^[1-9][0-9]*$'
}

if ! is_positive_integer "$DB_CHECK_REVIEWER_WAIT_ATTEMPTS"; then
  echo "DB_CHECK_REVIEWER_WAIT_ATTEMPTS must be a positive integer." >&2
  exit 2
fi

if ! is_positive_integer "$DB_CHECK_REVIEWER_WAIT_SECONDS"; then
  echo "DB_CHECK_REVIEWER_WAIT_SECONDS must be a positive integer." >&2
  exit 2
fi

fetch_pr_json() {
  curl -fsS "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests/${BITBUCKET_PR_ID}" \
    -u "${BITBUCKET_API_USERNAME}:${BITBUCKET_API_TOKEN}" \
    -H "Accept: application/json"
}

has_db_check_reviewer() {
  local pr_json="${1:?pr_json required}"
  local uuid account_id nickname display_name
  while IFS=$'\t' read -r uuid account_id nickname display_name; do
    if matches_csv "$uuid" "${DB_CHECK_REVIEWER_UUID:-}" \
      || matches_csv "$account_id" "${DB_CHECK_REVIEWER_ACCOUNT_ID:-}" \
      || matches_csv "$nickname" "${DB_CHECK_REVIEWER_NICKNAME:-}" \
      || matches_csv "$display_name" "${DB_CHECK_REVIEWER_DISPLAY_NAME:-}"; then
      return 0
    fi
  done < <(printf '%s' "$pr_json" | jq -r '.reviewers[]? | [.uuid // "", .account_id // "", .nickname // "", .display_name // ""] | @tsv')

  return 1
}

reviewer_selected=false
for attempt in $(seq 1 "$DB_CHECK_REVIEWER_WAIT_ATTEMPTS"); do
  pr_json="$(fetch_pr_json)"
  if has_db_check_reviewer "$pr_json"; then
    reviewer_selected=true
    break
  fi

  if [ "$attempt" -lt "$DB_CHECK_REVIEWER_WAIT_ATTEMPTS" ]; then
    echo "DB-check reviewer is not visible yet on PR #${BITBUCKET_PR_ID}; retrying in ${DB_CHECK_REVIEWER_WAIT_SECONDS}s (${attempt}/${DB_CHECK_REVIEWER_WAIT_ATTEMPTS})."
    sleep "$DB_CHECK_REVIEWER_WAIT_SECONDS"
  fi
done

if [ "$reviewer_selected" != "true" ]; then
  echo "DB-check reviewer is not selected on PR #${BITBUCKET_PR_ID} after ${DB_CHECK_REVIEWER_WAIT_ATTEMPTS} attempt(s); skipping schema review."
  exit 0
fi

echo "DB-check reviewer selected; running schema review."

: "${POSTGRES_HOST:?POSTGRES_HOST is required}"
: "${POSTGRES_PORT:?POSTGRES_PORT is required}"
: "${POSTGRES_DATABASE:?POSTGRES_DATABASE is required}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"

if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "Using Claude Code OAuth token for schema review."
  unset ANTHROPIC_API_KEY
  claude_env=()
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Using Anthropic API key for schema review."
  claude_env=("CLAUDE_CODE_SIMPLE=1")
else
  echo "CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY is required" >&2
  exit 1
fi

export POSTGRES_QUERY_PARAMS="${POSTGRES_QUERY_PARAMS:-sslmode=require}"
POSTGRES_SSLMODE="${POSTGRES_SSLMODE:-$(printf '%s' "$POSTGRES_QUERY_PARAMS" | tr '&' '\n' | awk -F= '$1 == "sslmode" { print $2; exit }')}"
POSTGRES_SSLMODE="${POSTGRES_SSLMODE:-require}"

write_live_schema_snapshot() {
  local output="${1:?output required}"
  local tmp="${output}.tmp"

  rm -f "$tmp"
  export PGPASSWORD="$POSTGRES_PASSWORD"
  export PGSSLMODE="$POSTGRES_SSLMODE"

  if ! psql -v ON_ERROR_STOP=1 -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" -At > "$tmp" <<'SQL'
with
tables as (
  select coalesce(jsonb_agg(to_jsonb(t) order by table_schema, table_name), '[]'::jsonb) as data
  from (
    select table_schema, table_name, table_type
    from information_schema.tables
    where table_schema not in ('pg_catalog', 'information_schema')
  ) t
),
columns as (
  select coalesce(jsonb_agg(to_jsonb(c) order by table_schema, table_name, ordinal_position), '[]'::jsonb) as data
  from (
    select
      table_schema,
      table_name,
      column_name,
      ordinal_position,
      data_type,
      udt_name,
      is_nullable,
      column_default,
      character_maximum_length,
      numeric_precision,
      numeric_scale,
      datetime_precision
    from information_schema.columns
    where table_schema not in ('pg_catalog', 'information_schema')
  ) c
),
constraints as (
  select coalesce(jsonb_agg(to_jsonb(c) order by table_schema, table_name, constraint_name, ordinal_position nulls last), '[]'::jsonb) as data
  from (
    select
      tc.table_schema,
      tc.table_name,
      tc.constraint_name,
      tc.constraint_type,
      kcu.column_name,
      kcu.ordinal_position,
      ccu.table_schema as foreign_table_schema,
      ccu.table_name as foreign_table_name,
      ccu.column_name as foreign_column_name,
      cc.check_clause
    from information_schema.table_constraints tc
    left join information_schema.key_column_usage kcu
      on tc.constraint_schema = kcu.constraint_schema
      and tc.constraint_name = kcu.constraint_name
      and tc.table_schema = kcu.table_schema
      and tc.table_name = kcu.table_name
    left join information_schema.constraint_column_usage ccu
      on tc.constraint_schema = ccu.constraint_schema
      and tc.constraint_name = ccu.constraint_name
    left join information_schema.check_constraints cc
      on tc.constraint_schema = cc.constraint_schema
      and tc.constraint_name = cc.constraint_name
    where tc.table_schema not in ('pg_catalog', 'information_schema')
  ) c
),
indexes as (
  select coalesce(jsonb_agg(to_jsonb(i) order by schemaname, tablename, indexname), '[]'::jsonb) as data
  from (
    select schemaname, tablename, indexname, indexdef
    from pg_indexes
    where schemaname not in ('pg_catalog', 'information_schema')
  ) i
),
views as (
  select coalesce(jsonb_agg(to_jsonb(v) order by schemaname, viewname), '[]'::jsonb) as data
  from (
    select schemaname, viewname, definition
    from pg_views
    where schemaname not in ('pg_catalog', 'information_schema')
  ) v
)
select jsonb_pretty(jsonb_build_object(
  'generated_at', now(),
  'database', current_database(),
  'schemas', (
    select coalesce(jsonb_agg(nspname order by nspname), '[]'::jsonb)
    from pg_namespace
    where nspname not like 'pg_%'
      and nspname <> 'information_schema'
  ),
  'tables', (select data from tables),
  'columns', (select data from columns),
  'constraints', (select data from constraints),
  'indexes', (select data from indexes),
  'views', (select data from views)
))::text;
SQL
  then
    rm -f "$tmp"
    return 1
  fi

  if ! jq empty "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$output"
}

git fetch origin "${BITBUCKET_PR_DESTINATION_BRANCH}" || true
if git rev-parse "origin/${BITBUCKET_PR_DESTINATION_BRANCH}" >/dev/null 2>&1; then
  git diff "origin/${BITBUCKET_PR_DESTINATION_BRANCH}...HEAD" -- "src/**" > pr.diff || true
else
  git diff HEAD~1 -- "src/**" > pr.diff || true
fi

echo "----- changed source diff -----"
head -n 200 pr.diff || true

rm -f verdict.json live-schema.json live-schema.json.tmp

schema_snapshot_ready=false
echo "Writing live PostgreSQL schema snapshot to live-schema.json..."
if write_live_schema_snapshot "live-schema.json"; then
  schema_snapshot_ready=true
  echo "----- live schema snapshot summary -----"
  jq '{tables: (.tables | length), columns: (.columns | length), constraints: (.constraints | length), indexes: (.indexes | length), views: (.views | length)}' live-schema.json
else
  echo "Live PostgreSQL schema snapshot failed; writing a blocking schema verdict." >&2
  printf '%s' '{"summary":"live PostgreSQL schema could not be read from the configured database","errors":[{"category":"internal","file":"-","line":0,"code_snippet":"-","problem":"live PostgreSQL schema snapshot failed before AI review","schema_evidence":"psql could not read information_schema/pg_catalog from the configured POSTGRES_* connection","suggestion":"check POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DATABASE, POSTGRES_USER, POSTGRES_PASSWORD, SSL mode, and database network access from Bitbucket Pipelines"}],"warnings":[]}' > verdict.json
fi

if [ "$schema_snapshot_ready" = "true" ]; then
  if ! command -v claude >/dev/null 2>&1; then
    npm install -g @anthropic-ai/claude-code
  fi

  set +e
  env "${claude_env[@]}" claude -p "Read ci/review-prompt.md and follow it exactly. The diff of changed source files is in pr.diff. The live PostgreSQL schema snapshot is in live-schema.json; treat it as authoritative and do not fall back to db/schema.sql. Write verdict.json at the repository root." \
    --model "$CLAUDE_MODEL" \
    --allowedTools "Read,Write,Bash(git diff:*),Bash(cat:*)"
  claude_exit=$?
  set -e

  if [ "$claude_exit" -ne 0 ]; then
    echo "Claude schema review exited with status ${claude_exit}; verdict.json will decide the gate if present." >&2
  fi
fi

if [ ! -f verdict.json ]; then
  printf '%s' '{"summary":"review did not produce verdict.json","errors":[{"category":"internal","file":"-","line":0,"code_snippet":"-","problem":"verdict.json missing - the AI review step did not write a result","schema_evidence":"-","suggestion":"check the schema review step logs"}],"warnings":[]}' > verdict.json
fi

err_count=$(jq '(.errors // []) | length' verdict.json)
warn_count=$(jq '(.warnings // []) | length' verdict.json)

if [ "$err_count" -gt 0 ]; then
  status="error"
elif [ "$warn_count" -gt 0 ]; then
  status="warning"
else
  status="pass"
fi

export SCM_PROVIDER="bitbucket"
export REVIEW_MODEL="$CLAUDE_MODEL"
export PROJECT_NAME="${BITBUCKET_REPO_FULL_NAME:-${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}}"
export GIT_BRANCH="${BITBUCKET_BRANCH}"
export PR_NUMBER="${BITBUCKET_PR_ID}"
export COMMIT_SHA="${BITBUCKET_COMMIT}"
export REPO="${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}"
export SLACK_CHANNEL="${SLACK_CHANNEL:-${SLACK_CHANNEL_ID:-}}"

bash ci/bitbucket-review-decision.sh "$status"

notify_slack() {
  local notify_status="${1:?status required}"
  if [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_CHANNEL:-}" ]; then
    bash ci/notify-slack.sh "$notify_status"
    return 0
  fi
  if [ "$notify_status" = "warning" ]; then
    echo "SLACK_BOT_TOKEN and SLACK_CHANNEL or SLACK_CHANNEL_ID are required for warning approval." >&2
    return 1
  fi
  echo "Slack notification skipped; Slack variables are not configured."
}

notify_slack "$status"

case "$status" in
  pass)
    echo "DB schema gate passed."
    ;;
  warning)
    echo "DB schema gate produced warnings; bot requested changes until Slack approval."
    ;;
  error)
    echo "DB schema gate failed: schema review produced errors. This is not a compile/build failure."
    exit 1
    ;;
esac
