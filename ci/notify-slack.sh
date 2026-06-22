#!/usr/bin/env bash
# Posts the schema-review result to Slack via chat.postMessage.
set -euo pipefail

STATUS="${1:?status required: pass|warning|error}"
VERDICT_FILE="${VERDICT_FILE:-verdict.json}"
SCM_PROVIDER="${SCM_PROVIDER:-github}"
REVIEW_MODEL="${REVIEW_MODEL:-${CLAUDE_MODEL:-unknown}}"
BITBUCKET_DECISION_APPLIED="${BITBUCKET_DECISION_APPLIED:-true}"

: "${SLACK_BOT_TOKEN:?SLACK_BOT_TOKEN is required}"
: "${SLACK_CHANNEL:?SLACK_CHANNEL is required}"

PROJECT_NAME="${PROJECT_NAME:-unknown-project}"
GIT_BRANCH="${GIT_BRANCH:-unknown}"
PR_NUMBER="${PR_NUMBER:-}"
COMMIT_SHA="${COMMIT_SHA:-}"
REPO="${REPO:-}"

case "$STATUS" in
  pass) HEADER="DB Schema Gate: PASSED" ;;
  warning) HEADER="DB Schema Gate: WARNING" ;;
  error) HEADER="DB Schema Gate: FAILED" ;;
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

FALLBACK="$HEADER"

if [ -f "$VERDICT_FILE" ]; then
  ERR_COUNT=$(jq '(.errors // []) | length' "$VERDICT_FILE")
  WARN_COUNT=$(jq '(.warnings // []) | length' "$VERDICT_FILE")
  FALLBACK="${HEADER}: ${ERR_COUNT} error(s), ${WARN_COUNT} warning(s)"
  intro=$(jq -n --arg status "$STATUS" --arg e "$ERR_COUNT" --arg w "$WARN_COUNT" --arg model "$REVIEW_MODEL" --arg decision_applied "$BITBUCKET_DECISION_APPLIED" '
    def count_label($n; $singular; $plural):
      ($n | tonumber) as $count
      | (($count | tostring) + " " + (if $count == 1 then $singular else $plural end));
    def gate:
      if $status == "error" then "Blocked - schema errors found"
      elif $status == "warning" then "Waiting for Slack decision"
      else "Passed"
      end;
    def action:
      if $decision_applied != "true" then "Bitbucket update failed; see CI logs"
      elif $status == "error" then "PR declined"
      elif $status == "warning" then "Reviewer holds PR until approval"
      else "Reviewer approved"
      end;
    [
      { type: "section", fields: [
          { type: "mrkdwn", text: ("*Gate*\n" + gate) },
          { type: "mrkdwn", text: ("*Findings*\n" + count_label($e; "error"; "errors") + ", " + count_label($w; "warning"; "warnings")) },
          { type: "mrkdwn", text: ("*Action*\n" + action) },
          { type: "mrkdwn", text: ("*Model*\n" + $model) }
        ] },
      { type: "divider" }
    ]')
  cards=$(jq '
    def clean:
      tostring
      | gsub("[\r\n\t]+"; " ")
      | gsub("  +"; " ");
    def trunc($max):
      clean as $text
      | if ($text | length) > $max then ($text[0:($max - 3)] + "...") else $text end;
    def loc(f):
      (f.file // "?") + ":" + ((f.line // 0) | tostring);
    def inline($value; $max):
      ($value // "" | trunc($max) | gsub("`"; ""));
    def card(n; lbl; f):
      { type: "section", text: { type: "mrkdwn",
          text: ("*" + ((n + 1) | tostring) + ". " + lbl + "* `" + (f.category // "issue") + "` at `" + loc(f) + "`\n\n"
                 + (if ((f.code_snippet // "") | length) > 0 then ("*Code:*\n`" + inline(f.code_snippet; 180) + "`\n\n") else "" end)
                 + "*Problem:*\n" + ((f.problem // "No problem text provided.") | trunc(420)) + "\n\n"
                 + "*Suggested fix:*\n" + ((f.suggestion // "Check the CI logs for the full recommendation.") | trunc(260))) } };
    ( [ (.errors // [])[] | { l: "ERROR", f: . } ]
      + [ (.warnings // [])[] | { l: "WARNING", f: . } ] ) as $all
    | ($all[0:6]) as $shown
    | if ($all | length) == 0 then
        [ { type: "section", text: { type: "mrkdwn", text: "*Result*\nNo schema issues found." } } ]
      else
        [ { type: "section", text: { type: "mrkdwn", text: "*Top findings*" } } ]
        + [ $shown | to_entries[] | card(.key; .value.l; .value.f) ]
        + (if ($all | length) > 6
           then [ { type: "context", elements: [ { type: "mrkdwn",
                    text: ("Showing 6 of " + (($all | length) | tostring) + " findings. See CI logs for the full verdict.") } ] } ]
           else [] end)
      end
      + (if ((.summary // "") | length) > 0
         then [ { type: "context", elements: [ { type: "mrkdwn",
                  text: ("Reviewer summary: " + ((.summary // "") | trunc(360))) } ] } ]
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

payload=$(jq -n --arg ch "$SLACK_CHANNEL" --arg fb "$FALLBACK" --argjson blocks "$blocks" \
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
