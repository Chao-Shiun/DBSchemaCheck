#!/usr/bin/env bash
# Applies the DB schema review result to a Bitbucket pull request as the API user.
set -euo pipefail

STATUS="${1:?status required: pass|warning|error}"

: "${BITBUCKET_API_USERNAME:?BITBUCKET_API_USERNAME is required}"
: "${BITBUCKET_API_TOKEN:?BITBUCKET_API_TOKEN is required}"
: "${BITBUCKET_WORKSPACE:?BITBUCKET_WORKSPACE is required}"
: "${BITBUCKET_REPO_SLUG:?BITBUCKET_REPO_SLUG is required}"
: "${BITBUCKET_PR_ID:?BITBUCKET_PR_ID is required}"

API_BASE="https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests/${BITBUCKET_PR_ID}"

bb_post() {
  local path="${1:?path required}"
  curl -fsS -X POST "${API_BASE}${path}" \
    -u "${BITBUCKET_API_USERNAME}:${BITBUCKET_API_TOKEN}" \
    -H "Accept: application/json" >/dev/null
}

bb_delete_optional() {
  local path="${1:?path required}"
  local status_code
  status_code=$(curl -sS -o /tmp/bitbucket-delete-response.txt -w "%{http_code}" -X DELETE "${API_BASE}${path}" \
    -u "${BITBUCKET_API_USERNAME}:${BITBUCKET_API_TOKEN}" \
    -H "Accept: application/json")
  if [ "$status_code" -ge 200 ] && [ "$status_code" -lt 300 ]; then
    return 0
  fi
  if [ "$status_code" = "400" ] || [ "$status_code" = "404" ]; then
    return 0
  fi
  cat /tmp/bitbucket-delete-response.txt >&2 || true
  return 1
}

case "$STATUS" in
  pass)
    bb_delete_optional "/request-changes"
    bb_post "/approve"
    echo "Bitbucket reviewer decision: approved"
    ;;
  warning)
    bb_delete_optional "/approve"
    bb_post "/request-changes"
    echo "Bitbucket reviewer decision: changes requested until Slack approval"
    ;;
  error)
    bb_delete_optional "/approve"
    bb_delete_optional "/request-changes"
    bb_post "/decline"
    echo "Bitbucket reviewer decision: pull request declined"
    ;;
  *)
    echo "unknown status: $STATUS" >&2
    exit 2
    ;;
esac
