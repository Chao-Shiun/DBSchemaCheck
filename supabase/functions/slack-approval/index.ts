// Supabase Edge Function: Slack interactivity endpoint for schema-gate approvals.
//
// Flow: a WARNING posts Slack buttons. When a user clicks 放行 / 拒絕, Slack POSTs here.
// This function verifies the Slack signature, sets the GitHub `schema-gate` commit status,
// updates the Slack message, and (on approve) triggers a repository_dispatch so the
// deploy/merge flow can continue.
//
// It ACKs Slack with HTTP 200 within Slack's 3-second window, then finishes the GitHub/Slack
// calls out-of-band via EdgeRuntime.waitUntil so a slow GitHub API can't cause a Slack timeout
// (which would trigger retries and duplicate dispatches).
//
// Required function secrets (supabase secrets set ...):
//   SLACK_SIGNING_SECRET  - to verify Slack request signatures
//   GH_DISPATCH_TOKEN     - GitHub token with statuses:write + repo dispatch (least privilege)
//   APPROVER_SLACK_IDS    - optional, comma-separated Slack user IDs allowed to decide
import { createHmac } from "node:crypto";

const SLACK_SIGNING_SECRET = Deno.env.get("SLACK_SIGNING_SECRET") ?? "";
const GH_TOKEN = Deno.env.get("GH_DISPATCH_TOKEN") ?? "";
const APPROVER_IDS = (Deno.env.get("APPROVER_SLACK_IDS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);

const GH_HEADERS = {
  "Authorization": `Bearer ${GH_TOKEN}`,
  "Accept": "application/vnd.github+json",
  "Content-Type": "application/json",
  "User-Agent": "dbschemacheck-slack-approval",
};

function verifySlackSignature(timestamp: string, signature: string, rawBody: string): boolean {
  if (!timestamp || !signature || !SLACK_SIGNING_SECRET) return false;
  const age = Math.abs(Date.now() / 1000 - Number(timestamp));
  if (Number.isNaN(age) || age > 300) return false; // reject replays older than 5 minutes
  const hmac = createHmac("sha256", SLACK_SIGNING_SECRET).update(`v0:${timestamp}:${rawBody}`).digest("hex");
  const expected = `v0=${hmac}`;
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  return diff === 0;
}

// POST to the GitHub API and report whether it succeeded. fetch does not throw on 4xx/5xx,
// so the response MUST be checked or failures are silent.
async function ghPost(url: string, body: unknown): Promise<{ ok: boolean; status: number; detail: string }> {
  const res = await fetch(url, { method: "POST", headers: GH_HEADERS, body: JSON.stringify(body) });
  let detail = "";
  if (!res.ok) {
    detail = (await res.text()).slice(0, 300);
    console.error(`GitHub API ${url} -> ${res.status}: ${detail}`);
  }
  return { ok: res.ok, status: res.status, detail };
}

async function setCommitStatus(repo: string, sha: string, state: string, description: string) {
  return await ghPost(`https://api.github.com/repos/${repo}/statuses/${sha}`, { state, context: "schema-gate", description });
}

async function dispatch(repo: string, decision: string, pr: string, sha: string) {
  return await ghPost(`https://api.github.com/repos/${repo}/dispatches`, { event_type: "schema-approval", client_payload: { decision, pr, sha } });
}

async function updateSlackMessage(responseUrl: string, text: string) {
  if (!responseUrl) return;
  await fetch(responseUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ replace_original: true, text }),
  });
}

// Performs the decision side effects. Runs out-of-band (after the 200 ACK) via waitUntil.
async function processDecision(payload: Record<string, unknown>) {
  const action = (payload.actions as Array<Record<string, unknown>> | undefined)?.[0];
  const decision = action?.action_id as string | undefined; // "approve" | "reject"
  const userId = (payload.user as Record<string, unknown> | undefined)?.id as string ?? "";
  const responseUrl = payload.response_url as string;
  const meta = JSON.parse((action?.value as string) ?? "{}"); // { repo, sha, pr, channel }

  if (APPROVER_IDS.length > 0 && !APPROVER_IDS.includes(userId)) {
    await updateSlackMessage(responseUrl, `:no_entry: <@${userId}> 無核准權限，決策未生效。`);
    return;
  }

  const repo = meta.repo as string;
  const sha = meta.sha as string;

  if (decision === "approve") {
    const r = await setCommitStatus(repo, sha, "success", `approved by ${userId}`);
    if (r.ok) {
      await dispatch(repo, "approve", String(meta.pr ?? ""), sha);
      await updateSlackMessage(responseUrl, `:white_check_mark: 已由 <@${userId}> *放行*。schema-gate → success，繼續後續合併/佈署流程。`);
    } else {
      await updateSlackMessage(responseUrl, `:warning: <@${userId}> 按了 *放行*，但更新 GitHub schema-gate 失敗（HTTP ${r.status}）。PR 仍被擋。請確認 GH_DISPATCH_TOKEN 具備該 repo 的 Commit statuses: write 與 Contents: write 權限。`);
    }
  } else if (decision === "reject") {
    const r = await setCommitStatus(repo, sha, "failure", `rejected by ${userId}`);
    if (r.ok) {
      await updateSlackMessage(responseUrl, `:no_entry: 已由 <@${userId}> *拒絕*。schema-gate → failure，本次 CICD 取消。`);
    } else {
      await updateSlackMessage(responseUrl, `:warning: <@${userId}> 按了 *拒絕*（PR 仍為 pending、同樣會擋住合併），但更新 GitHub schema-gate 失敗（HTTP ${r.status}）。請確認 GH_DISPATCH_TOKEN 權限。`);
    }
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const rawBody = await req.text();
  const ts = req.headers.get("x-slack-request-timestamp") ?? "";
  const sig = req.headers.get("x-slack-signature") ?? "";
  if (!verifySlackSignature(ts, sig, rawBody)) return new Response("invalid signature", { status: 401 });

  // Slack sends application/x-www-form-urlencoded with a `payload` field holding the JSON.
  const payloadRaw = new URLSearchParams(rawBody).get("payload");
  if (!payloadRaw) return new Response("no payload", { status: 400 });
  const payload = JSON.parse(payloadRaw);

  // ACK immediately to stay within Slack's 3-second window; finish the work in the background.
  // EdgeRuntime is provided by the Supabase Edge runtime.
  // @ts-ignore - EdgeRuntime global is not in the default TS lib.
  EdgeRuntime.waitUntil(processDecision(payload).catch((e) => console.error("processDecision failed", e)));
  return new Response("ok", { status: 200 });
});
