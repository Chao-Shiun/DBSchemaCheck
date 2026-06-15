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
  pass)    HEADER="✅ Schema Check: SUCCESS" ;;
  warning) HEADER="⚠️ Schema Check: WARNING (等待核准)" ;;
  error)   HEADER="❌ Schema Check: FAILED" ;;
  *) echo "unknown status: $STATUS" >&2 ; exit 2 ;;
esac

SHORT_SHA="${COMMIT_SHA:0:7}"

# Header + a compact metadata context line (project, branch, PR, commit).
META_CTX="📦 ${PROJECT_NAME}"
[ -n "$GIT_BRANCH" ] && META_CTX="${META_CTX}   🌿 ${GIT_BRANCH}"
[ -n "$PR_NUMBER" ] && META_CTX="${META_CTX}   🔗 PR #${PR_NUMBER}"
[ -n "$SHORT_SHA" ] && META_CTX="${META_CTX}   \`${SHORT_SHA}\`"

blocks=$(jq -n --arg header "$HEADER" --arg meta "$META_CTX" '
  [
    { type: "header",  text: { type: "plain_text", text: $header, emoji: true } },
    { type: "context", elements: [ { type: "mrkdwn", text: $meta } ] }
  ]')

# Count line + AI summary + divider, then one card per finding (errors first, then warnings),
# each separated by a divider. Cap at 18 findings to stay within Slack's 50-block limit.
if [ -f "$VERDICT_FILE" ]; then
  ERR_COUNT=$(jq '(.errors // []) | length' "$VERDICT_FILE")
  WARN_COUNT=$(jq '(.warnings // []) | length' "$VERDICT_FILE")
  SUMMARY=$(jq -r '.summary // ""' "$VERDICT_FILE")
  intro=$(jq -n --arg e "$ERR_COUNT" --arg w "$WARN_COUNT" --arg s "$SUMMARY" '
    [ { type: "section", text: { type: "mrkdwn",
        text: (if ($e == "0" and $w == "0") then "🟢 無 schema 問題"
               else ("🔴 *" + $e + "* error  ·  🟠 *" + $w + "* warning") end) } } ]
    + (if ($s | length) > 0 then [ { type: "context", elements: [ { type: "mrkdwn", text: $s } ] } ] else [] end)
    + [ { type: "divider" } ]')
  cards=$(jq '
    def card(emoji; lbl; f):
      { type: "section", text: { type: "mrkdwn",
          text: (emoji + "  *" + lbl + "*  ·  `" + (f.category // "issue") + "`  ·  `" + (f.file // "?") + ":" + ((f.line // 0) | tostring) + "`\n"
                 + "*問題:* " + (f.problem // "") + "\n"
                 + "*Schema:* " + (f.schema_evidence // "-") + "\n"
                 + "*建議:* " + (f.suggestion // "")) } };
    ( [ (.errors // [])[]   | { e: "🛑", l: "ERROR",   f: . } ]
      + [ (.warnings // [])[] | { e: "⚠️", l: "WARNING", f: . } ] ) as $all
    | ($all[0:18]) as $shown
    | [ $shown[] | card(.e; .l; .f), { type: "divider" } ]
      + (if ($all | length) > 18
         then [ { type: "context", elements: [ { type: "mrkdwn",
                  text: ("…還有 " + ((($all | length) - 18) | tostring) + " 筆未顯示，完整內容見 GitHub Actions log") } ] } ]
         else [] end)
  ' "$VERDICT_FILE")
  blocks=$(jq -n --argjson a "$blocks" --argjson i "$intro" --argjson c "$cards" '$a + $i + $c')
fi

# For warnings, append approve / reject buttons. The value carries the context the
# Supabase Edge Function needs to dispatch the decision; the resume workflow sets the status.
if [ "$STATUS" = "warning" ]; then
  if [ -z "$REPO" ] || [ -z "$COMMIT_SHA" ]; then
    echo "REPO and COMMIT_SHA are required when posting warning approval buttons." >&2
    exit 1
  fi
  if ! printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    echo "Invalid REPO for warning approval buttons: $REPO" >&2
    exit 1
  fi
  if ! printf '%s' "$COMMIT_SHA" | grep -Eiq '^[0-9a-f]{40}$'; then
    echo "Invalid COMMIT_SHA for warning approval buttons: $COMMIT_SHA" >&2
    exit 1
  fi
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
