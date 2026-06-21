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

pr_json=$(curl -fsS "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests/${BITBUCKET_PR_ID}" \
  -u "${BITBUCKET_API_USERNAME}:${BITBUCKET_API_TOKEN}" \
  -H "Accept: application/json")

reviewer_selected=false
while IFS=$'\t' read -r uuid account_id nickname display_name; do
  if matches_csv "$uuid" "${DB_CHECK_REVIEWER_UUID:-}" \
    || matches_csv "$account_id" "${DB_CHECK_REVIEWER_ACCOUNT_ID:-}" \
    || matches_csv "$nickname" "${DB_CHECK_REVIEWER_NICKNAME:-}" \
    || matches_csv "$display_name" "${DB_CHECK_REVIEWER_DISPLAY_NAME:-}"; then
    reviewer_selected=true
    break
  fi
done < <(printf '%s' "$pr_json" | jq -r '.reviewers[]? | [.uuid // "", .account_id // "", .nickname // "", .display_name // ""] | @tsv')

if [ "$reviewer_selected" != "true" ]; then
  echo "DB-check reviewer is not selected on PR #${BITBUCKET_PR_ID}; skipping schema review."
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
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Using Anthropic API key for schema review."
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

curl -fsSL -o toolbox "https://storage.googleapis.com/mcp-toolbox-for-databases/v${TOOLBOX_VERSION}/linux/amd64/toolbox"
chmod +x toolbox

if ! command -v claude >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-code
fi

set +e
CLAUDE_CODE_SIMPLE=1 claude -p "Read ci/review-prompt.md and follow it exactly. The diff of changed source files is in pr.diff. Use the toolbox MCP tools to introspect the live PostgreSQL schema, then write verdict.json at the repository root." \
  --mcp-config ci/mcp-config.json \
  --model "$CLAUDE_MODEL" \
  --allowedTools "mcp__toolbox__list_tables,mcp__toolbox__list_indexes,mcp__toolbox__list_views,mcp__toolbox__execute_sql,mcp__toolbox__get_query_plan,Read,Write,Bash(git diff:*),Bash(cat:*)"
claude_exit=$?
set -e

if [ "$claude_exit" -ne 0 ]; then
  echo "Claude schema review exited with status ${claude_exit}; verdict.json will decide the gate if present." >&2
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
    echo "Schema review passed."
    ;;
  warning)
    echo "Schema review produced warnings; bot requested changes until Slack approval."
    ;;
  error)
    echo "Schema review produced errors; failing the pipeline."
    exit 1
    ;;
esac
