// Supabase Edge Function: Slack interactivity endpoint for schema-gate approvals.
//
// Flow: a WARNING posts Slack buttons. When a user clicks approve or reject, Slack POSTs here.
// This function verifies the Slack signature, then triggers repository_dispatch. The GitHub
// Actions resume job uses GITHUB_TOKEN to update the `schema-gate` commit status.
//
// Required function secrets (supabase secrets set ...):
//   SLACK_SIGNING_SECRET  - to verify Slack request signatures
//   GH_DISPATCH_TOKEN     - GitHub token with Contents: read/write for repository_dispatch
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
  "X-GitHub-Api-Version": "2022-11-28",
};

type Decision = "approve" | "reject";

type ButtonMeta = {
  repo?: string;
  sha?: string;
  pr?: string;
  channel?: string;
};

type GitHubResult = {
  ok: boolean;
  status: number;
  detail: string;
  url: string;
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

function isValidRepo(repo: string): boolean {
  return /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo);
}

function isValidSha(sha: string): boolean {
  return /^[0-9a-f]{40}$/i.test(sha);
}

function cleanForSlack(text: string, maxLength: number): string {
  return text.replace(/[`<>]/g, "").slice(0, maxLength);
}

async function ghPost(path: string, body: unknown): Promise<GitHubResult> {
  const url = `https://api.github.com${path}`;
  try {
    const res = await fetch(url, { method: "POST", headers: GH_HEADERS, body: JSON.stringify(body) });
    const detail = res.ok ? "" : cleanForSlack(await res.text(), 300);
    if (!res.ok) console.error(`GitHub API ${url} -> ${res.status}: ${detail}`);
    return { ok: res.ok, status: res.status, detail, url };
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(`GitHub API ${url} failed: ${detail}`);
    return { ok: false, status: 0, detail: cleanForSlack(detail, 300), url };
  }
}

async function dispatchDecision(repo: string, decision: Decision, pr: string, sha: string, approver: string) {
  return await ghPost(`/repos/${repo}/dispatches`, { event_type: "schema-approval", client_payload: { decision, pr, sha, approver } });
}

async function updateSlackMessage(responseUrl: string, text: string) {
  if (!responseUrl) return;
  await fetch(responseUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ replace_original: true, text }),
  });
}

function githubFailureMessage(userId: string, decisionText: string, result: GitHubResult, repo: string, sha: string): string {
  const statusText = result.status === 0 ? "network error" : `HTTP ${result.status}`;
  const shortSha = sha.slice(0, 7);
  const detail = result.detail ? ` GitHub response: \`${cleanForSlack(result.detail, 180)}\`` : "";
  return `:warning: <@${userId}> 按了 *${decisionText}*，但無法觸發 GitHub repository_dispatch（${statusText}）。PR 仍會維持 pending。請確認 Supabase secret \`GH_DISPATCH_TOKEN\` 是最新 token，且對 \`${repo}\` 具備 Contents: read/write。commit: \`${shortSha}\`.${detail}`;
}

// Performs the decision side effects. Runs out-of-band after the 200 ACK via waitUntil.
async function processDecision(payload: Record<string, unknown>) {
  const action = (payload.actions as Array<Record<string, unknown>> | undefined)?.[0];
  const decision = action?.action_id as Decision | undefined;
  const userId = (payload.user as Record<string, unknown> | undefined)?.id as string ?? "";
  const responseUrl = payload.response_url as string;

  if (decision !== "approve" && decision !== "reject") {
    await updateSlackMessage(responseUrl, `:warning: <@${userId}> 收到未知決策，未變更 schema-gate。`);
    return;
  }

  if (APPROVER_IDS.length > 0 && !APPROVER_IDS.includes(userId)) {
    await updateSlackMessage(responseUrl, `:no_entry: <@${userId}> 無核准權限，決策未生效。`);
    return;
  }

  let meta: ButtonMeta;
  try {
    meta = JSON.parse((action?.value as string | undefined) ?? "{}") as ButtonMeta;
  } catch {
    await updateSlackMessage(responseUrl, `:warning: <@${userId}> Slack 按鈕內容無法解析，未變更 schema-gate。`);
    return;
  }

  const repo = (meta.repo ?? "").trim();
  const sha = (meta.sha ?? "").trim();
  const pr = String(meta.pr ?? "");

  if (!isValidRepo(repo) || !isValidSha(sha)) {
    await updateSlackMessage(responseUrl, `:warning: <@${userId}> Slack 按鈕缺少有效 repo 或 commit SHA，未變更 schema-gate。請重新執行 DB Schema Check 產生新的 WARNING 訊息。repo=\`${cleanForSlack(repo, 80)}\`, sha=\`${cleanForSlack(sha, 80)}\``);
    return;
  }

  const result = await dispatchDecision(repo, decision, pr, sha, userId);
  const decisionText = decision === "approve" ? "放行" : "拒絕";
  if (!result.ok) {
    await updateSlackMessage(responseUrl, githubFailureMessage(userId, decisionText, result, repo, sha));
    return;
  }

  if (decision === "approve") {
    await updateSlackMessage(responseUrl, `:white_check_mark: 已由 <@${userId}> *放行*。已送出 GitHub Actions resume job，將由 workflow 把 schema-gate 更新為 success。`);
  } else {
    await updateSlackMessage(responseUrl, `:no_entry: 已由 <@${userId}> *拒絕*。已送出 GitHub Actions resume job，將由 workflow 把 schema-gate 更新為 failure。`);
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
