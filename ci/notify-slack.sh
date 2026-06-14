#!/usr/bin/env bash
# Posts the schema-review result to Slack via chat.postMessage.
# Always sends a message (success / warning / failure).
# Usage: ci/notify-slack.sh <status>   where <status> is one of: pass | warning | error
set -euo pipefail

STATUS="${1:?status required: pass|warning|error}"
VERDICT_FILE="${VERDICT_FILE:-verdict.json}"

# Required environment variables (provided by the workflow).
: "${SLACK_BOT_TOKEN:?SLACK_BOT_TOKEN is required}"
: "${SLACK_CHANNEL:?SLACK_CHANNEL is required}"
PROJECT_NAME="${PROJECT_NAME:-unknown-project}"
GIT_BRANCH="${GIT_BRANCH:-unknown}"
PR_NUMBER="${PR_NUMBER:-}"
COMMIT_SHA="${COMMIT_SHA:-}"
REPO="${REPO:-}"

case "$STATUS" in
  pass)    HEADER="✅ Schema Check: SUCCESS" ; STATUS_TEXT="SUCCESS" ;;
  warning) HEADER="⚠️ Schema Check: WARNING (等待核准)" ; STATUS_TEXT="WARNING" ;;
  error)   HEADER="❌ Schema Check: FAILED" ; STATUS_TEXT="FAILED" ;;
  *) echo "unknown status: $STATUS" >&2 ; exit 2 ;;
esac

SHORT_SHA="${COMMIT_SHA:0:7}"

# Build the metadata section (tag name, project name, status, PR, commit) as required.
META_TEXT="*專案 (Project):* ${PROJECT_NAME}"$'\n'"*Branch:* ${GIT_BRANCH}"$'\n'"*狀態 (Status):* ${STATUS_TEXT}"
[ -n "$PR_NUMBER" ] && META_TEXT="${META_TEXT}"$'\n'"*PR:* #${PR_NUMBER}"
[ -n "$SHORT_SHA" ] && META_TEXT="${META_TEXT}"$'\n'"*Commit:* ${SHORT_SHA}"

blocks=$(jq -n --arg header "$HEADER" --arg meta "$META_TEXT" '
  [
    { type: "header",  text: { type: "plain_text", text: $header, emoji: true } },
    { type: "section", text: { type: "mrkdwn", text: $meta } }
  ]')

# Append a section per finding (errors first, then warnings) so failures/warnings are fully explained.
if [ -f "$VERDICT_FILE" ]; then
  issue_blocks=$(jq '
    def fmt(kind; lbl):
      (.[kind] // []) | map(
        { type: "section",
          text: { type: "mrkdwn",
            text: ("*[" + lbl + "] " + (.category // "issue") + "*\n"
                   + "`" + (.file // "?") + ":" + ((.line // 0) | tostring) + "`\n"
                   + "問題: " + (.problem // "") + "\n"
                   + "Schema 實況: " + (.schema_evidence // "-") + "\n"
                   + "建議: " + (.suggestion // "")) } } );
    (fmt("errors"; "ERROR") + fmt("warnings"; "WARNING"))
  ' "$VERDICT_FILE")
  blocks=$(jq -n --argjson a "$blocks" --argjson b "$issue_blocks" '$a + $b')
fi

# For warnings, append approve / reject buttons. The value carries the context the
# Supabase Edge Function needs to set the commit status and dispatch the decision.
if [ "$STATUS" = "warning" ]; then
  btn_value=$(jq -n --arg repo "$REPO" --arg sha "$COMMIT_SHA" --arg pr "$PR_NUMBER" --arg ch "$SLACK_CHANNEL" \
    '{ repo: $repo, sha: $sha, pr: $pr, channel: $ch } | tostring')
  actions=$(jq -n --arg v "$btn_value" '
    [ { type: "actions", elements: [
        { type: "button", style: "primary", action_id: "approve", text: { type: "plain_text", text: "放行 ✅", emoji: true }, value: $v },
        { type: "button", style: "danger",  action_id: "reject",  text: { type: "plain_text", text: "拒絕 ⛔", emoji: true }, value: $v }
      ] } ]')
  blocks=$(jq -n --argjson a "$blocks" --argjson b "$actions" '$a + $b')
fi

payload=$(jq -n --arg ch "$SLACK_CHANNEL" --arg fb "$HEADER" --argjson blocks "$blocks" \
  '{ channel: $ch, text: $fb, blocks: $blocks }')

resp=$(curl -sS -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data "$payload")

if [ "$(echo "$resp" | jq -r '.ok')" != "true" ]; then
  echo "Slack post failed: $resp" >&2
  exit 1
fi
echo "Slack notification sent (${STATUS})."
