#!/usr/bin/env bash
# Posts the schema-review result to Slack via chat.postMessage.
set -euo pipefail

STATUS="${1:?status required: pass|warning|error}"
VERDICT_FILE="${VERDICT_FILE:-verdict.json}"
SCM_PROVIDER="${SCM_PROVIDER:-github}"

: "${SLACK_BOT_TOKEN:?SLACK_BOT_TOKEN is required}"
: "${SLACK_CHANNEL:?SLACK_CHANNEL is required}"

PROJECT_NAME="${PROJECT_NAME:-unknown-project}"
GIT_BRANCH="${GIT_BRANCH:-unknown}"
PR_NUMBER="${PR_NUMBER:-}"
COMMIT_SHA="${COMMIT_SHA:-}"
REPO="${REPO:-}"

case "$STATUS" in
  pass) HEADER="Schema Check: SUCCESS" ;;
  warning) HEADER="Schema Check: WARNING (approval required)" ;;
  error) HEADER="Schema Check: FAILED" ;;
  *) echo "unknown status: $STATUS" >&2; exit 2 ;;
esac

SHORT_SHA="${COMMIT_SHA:0:7}"
META_CTX="${PROJECT_NAME}"
[ -n "$GIT_BRANCH" ] && META_CTX="${META_CTX} | ${GIT_BRANCH}"
[ -n "$PR_NUMBER" ] && META_CTX="${META_CTX} | PR #${PR_NUMBER}"
[ -n "$SHORT_SHA" ] && META_CTX="${META_CTX} | \`${SHORT_SHA}\`"

blocks=$(jq -n --arg header "$HEADER" --arg meta "$META_CTX" '
  [
    { type: "header", text: { type: "plain_text", text: $header, emoji: true } },
    { type: "context", elements: [ { type: "mrkdwn", text: $meta } ] }
  ]')

if [ -f "$VERDICT_FILE" ]; then
  ERR_COUNT=$(jq '(.errors // []) | length' "$VERDICT_FILE")
  WARN_COUNT=$(jq '(.warnings // []) | length' "$VERDICT_FILE")
  SUMMARY=$(jq -r '.summary // ""' "$VERDICT_FILE")
  intro=$(jq -n --arg e "$ERR_COUNT" --arg w "$WARN_COUNT" --arg s "$SUMMARY" '
    [ { type: "section", text: { type: "mrkdwn",
        text: (if ($e == "0" and $w == "0") then "No schema issues found."
               else ("*" + $e + "* error(s), *" + $w + "* warning(s)") end) } } ]
    + (if ($s | length) > 0 then [ { type: "context", elements: [ { type: "mrkdwn", text: $s } ] } ] else [] end)
    + [ { type: "divider" } ]')
  cards=$(jq '
    def card(lbl; f):
      { type: "section", text: { type: "mrkdwn",
          text: ("*" + lbl + "* | `" + (f.category // "issue") + "` | `" + (f.file // "?") + ":" + ((f.line // 0) | tostring) + "`\n"
                 + "*Problem:* " + (f.problem // "") + "\n"
                 + "*Schema:* " + (f.schema_evidence // "-") + "\n"
                 + "*Suggestion:* " + (f.suggestion // "")) } };
    ( [ (.errors // [])[] | { l: "ERROR", f: . } ]
      + [ (.warnings // [])[] | { l: "WARNING", f: . } ] ) as $all
    | ($all[0:18]) as $shown
    | [ $shown[] | card(.l; .f), { type: "divider" } ]
      + (if ($all | length) > 18
         then [ { type: "context", elements: [ { type: "mrkdwn",
                  text: ("There are " + ((($all | length) - 18) | tostring) + " more findings. See the CI logs for the full verdict.") } ] } ]
         else [] end)
  ' "$VERDICT_FILE")
  blocks=$(jq -n --argjson a "$blocks" --argjson i "$intro" --argjson c "$cards" '$a + $i + $c')
fi

if [ "$STATUS" = "warning" ]; then
  if [ -z "$REPO" ] || [ -z "$COMMIT_SHA" ]; then
    echo "REPO and COMMIT_SHA are required when posting warning approval buttons." >&2
    exit 1
  fi
  if [ "$SCM_PROVIDER" = "bitbucket" ] && [ -z "$PR_NUMBER" ]; then
    echo "PR_NUMBER is required for Bitbucket warning approval buttons." >&2
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
  btn_value=$(jq -nc --arg provider "$SCM_PROVIDER" --arg repo "$REPO" --arg sha "$COMMIT_SHA" --arg pr "$PR_NUMBER" --arg ch "$SLACK_CHANNEL" \
    '{ provider: $provider, repo: $repo, sha: $sha, pr: $pr, channel: $ch }')
  actions=$(jq -n --arg v "$btn_value" '
    [ { type: "actions", elements: [
        { type: "button", style: "primary", action_id: "approve", text: { type: "plain_text", text: "Approve", emoji: true }, value: $v },
        { type: "button", style: "danger", action_id: "reject", text: { type: "plain_text", text: "Reject", emoji: true }, value: $v }
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
