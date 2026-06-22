#!/usr/bin/env bash
# Runs the schema review only when the configured DB-check reviewer is selected on the PR.
set -euo pipefail

TOOLBOX_VERSION="${TOOLBOX_VERSION:-1.4.0}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-8}"

: "${BITBUCKET_PR_ID:?BITBUCKET_PR_ID is required; this script runs only for pull requests}"
: "${BITBUCKET_WORKSPACE:?BITBUCKET_WORKSPACE is required}"
: "${BITBUCKET_REPO_SLUG:?BITBUCKET_REPO_SLUG is required}"
: "${BITBUCKET_BRANCH:?BITBUCKET_BRANCH is required}"
: "${BITBUCKET_COMMIT:?BITBUCKET_COMMIT is required}"
: "${BITBUCKET_PR_DESTINATION_BRANCH:?BITBUCKET_PR_DESTINATION_BRANCH is required}"
DB_CHECK_REVIEWER_WAIT_ATTEMPTS="${DB_CHECK_REVIEWER_WAIT_ATTEMPTS:-12}"
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
apt-get install -y --no-install-recommends ca-certificates curl git jq

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

describe_pr_reviewers() {
  local pr_json="${1:?pr_json required}"
  printf '%s' "$pr_json" | jq -r '
    if ((.reviewers // []) | length) == 0 then
      "Current PR reviewers from API: <none>"
    else
      "Current PR reviewers from API:\n" + ((.reviewers // []) | map("- display_name=\(.display_name // "-"), nickname=\(.nickname // "-"), account_id=\(.account_id // "-"), uuid=\(.uuid // "-")") | join("\n"))
    end
  '
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
echo "DB-check reviewer selector status: uuid=$([ -n "${DB_CHECK_REVIEWER_UUID:-}" ] && echo configured || echo empty), account_id=$([ -n "${DB_CHECK_REVIEWER_ACCOUNT_ID:-}" ] && echo configured || echo empty), nickname=$([ -n "${DB_CHECK_REVIEWER_NICKNAME:-}" ] && echo configured || echo empty), display_name=$([ -n "${DB_CHECK_REVIEWER_DISPLAY_NAME:-}" ] && echo configured || echo empty)."
for attempt in $(seq 1 "$DB_CHECK_REVIEWER_WAIT_ATTEMPTS"); do
  pr_json="$(fetch_pr_json)"
  if has_db_check_reviewer "$pr_json"; then
    reviewer_selected=true
    break
  fi

  describe_pr_reviewers "$pr_json"

  if [ "$attempt" -lt "$DB_CHECK_REVIEWER_WAIT_ATTEMPTS" ]; then
    echo "DB-check reviewer is not visible yet on PR #${BITBUCKET_PR_ID}; retrying in ${DB_CHECK_REVIEWER_WAIT_SECONDS}s (${attempt}/${DB_CHECK_REVIEWER_WAIT_ATTEMPTS})."
    sleep "$DB_CHECK_REVIEWER_WAIT_SECONDS"
  fi
done

if [ "$reviewer_selected" != "true" ]; then
  echo "DB-check reviewer is not selected on PR #${BITBUCKET_PR_ID} after ${DB_CHECK_REVIEWER_WAIT_ATTEMPTS} attempt(s); skipping schema review. If DB Checker is visible in the UI, compare the API reviewer values above with DB_CHECK_REVIEWER_* repository variables."
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
  claude_env=()
else
  echo "CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY is required" >&2
  exit 1
fi

export POSTGRES_QUERY_PARAMS="${POSTGRES_QUERY_PARAMS:-sslmode=require}"

git fetch origin "${BITBUCKET_PR_DESTINATION_BRANCH}" || true
if git rev-parse "origin/${BITBUCKET_PR_DESTINATION_BRANCH}" >/dev/null 2>&1; then
  git diff "origin/${BITBUCKET_PR_DESTINATION_BRANCH}...HEAD" -- "src/**" > pr.diff || true
else
  git diff HEAD~1 -- "src/**" > pr.diff || true
fi

echo "----- changed source diff -----"
head -n 200 pr.diff || true

rm -f verdict.json toolbox mcp_init.json

echo "Downloading MCP Toolbox for Databases v${TOOLBOX_VERSION}..."
curl -fsSL -o toolbox "https://storage.googleapis.com/mcp-toolbox-for-databases/v${TOOLBOX_VERSION}/linux/amd64/toolbox"
chmod +x toolbox
toolbox_path="$(pwd)/toolbox"
echo "MCP Toolbox downloaded to ${toolbox_path}."

if ! command -v claude >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-code
fi

claude mcp remove toolbox >/dev/null 2>&1 || true
claude mcp add toolbox -s local \
  -e POSTGRES_HOST="$POSTGRES_HOST" \
  -e POSTGRES_PORT="$POSTGRES_PORT" \
  -e POSTGRES_DATABASE="$POSTGRES_DATABASE" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e POSTGRES_QUERY_PARAMS="$POSTGRES_QUERY_PARAMS" \
  -- "$toolbox_path" --prebuilt postgres --stdio
echo "MCP Toolbox registered through Claude Code local MCP config."
claude mcp list || true

set +e
env "${claude_env[@]}" claude -p "Read ci/review-prompt.md and follow it exactly. The diff of changed source files is in pr.diff. Use the registered toolbox MCP server to introspect the live PostgreSQL schema from Supabase. Do not use db/schema.sql as schema evidence. Write verdict.json at the repository root." \
  --model "$CLAUDE_MODEL" \
  --allowedTools "mcp__toolbox__list_schemas,mcp__toolbox__list_tables,mcp__toolbox__list_indexes,mcp__toolbox__list_views,mcp__toolbox__execute_sql,mcp__toolbox__get_query_plan,Read,Write,Bash(git diff:*),Bash(cat:*)"
claude_exit=$?
set -e

if [ "$claude_exit" -ne 0 ]; then
  echo "Claude schema review exited with status ${claude_exit}; verdict.json will decide the gate if present." >&2
fi

if [ ! -f verdict.json ]; then
  printf '%s' '{"summary":"review did not produce verdict.json","errors":[{"category":"internal","file":"-","line":0,"code_snippet":"-","problem":"verdict.json missing - the AI review step did not write a result","schema_evidence":"MCP Toolbox did not produce a usable schema review result","suggestion":"check the Claude and MCP Toolbox logs; verify POSTGRES_* variables and Claude MCP registration"}],"warnings":[]}' > verdict.json
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

set +e
bash ci/bitbucket-review-decision.sh "$status"
bitbucket_decision_status=$?
set -e

if [ "$bitbucket_decision_status" -eq 0 ]; then
  export BITBUCKET_DECISION_APPLIED="true"
else
  export BITBUCKET_DECISION_APPLIED="false"
  echo "Bitbucket reviewer decision failed with status ${bitbucket_decision_status}; Slack notification will still be attempted." >&2
fi

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

if [ "$bitbucket_decision_status" -ne 0 ]; then
  echo "DB schema gate result was computed, but Bitbucket reviewer decision could not be updated." >&2
  exit "$bitbucket_decision_status"
fi

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
