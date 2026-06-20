// Supabase Edge Function: Slack interactivity endpoint for schema-gate approvals.
//
// GitHub mode keeps the original repository_dispatch flow.
// Bitbucket mode applies the Slack decision directly as the configured bot reviewer:
// approve clears the bot's change request and approves the PR; reject requests changes.
import { createHmac } from "node:crypto";

const SLACK_SIGNING_SECRET = Deno.env.get("SLACK_SIGNING_SECRET") ?? "";
const GH_TOKEN = Deno.env.get("GH_DISPATCH_TOKEN") ?? "";
const BITBUCKET_API_USERNAME = Deno.env.get("BITBUCKET_API_USERNAME") ?? "";
const BITBUCKET_API_TOKEN = Deno.env.get("BITBUCKET_API_TOKEN") ?? "";
const APPROVER_IDS = (Deno.env.get("APPROVER_SLACK_IDS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);

type Decision = "approve" | "reject";
type Provider = "github" | "bitbucket";

type ButtonMeta = {
  provider?: Provider;
  repo?: string;
  sha?: string;
  pr?: string;
  channel?: string;
};

type HttpResult = {
  ok: boolean;
  status: number;
  detail: string;
  url: string;
};

function verifySlackSignature(timestamp: string, signature: string, rawBody: string): boolean {
  if (!timestamp || !signature || !SLACK_SIGNING_SECRET) return false;
  const age = Math.abs(Date.now() / 1000 - Number(timestamp));
  if (Number.isNaN(age) || age > 300) return false;
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

function isValidPullRequestId(pr: string): boolean {
  return /^[0-9]+$/.test(pr);
}

function cleanForSlack(text: string, maxLength: number): string {
  return text.replace(/[`<>]/g, "").slice(0, maxLength);
}

function githubHeaders(): HeadersInit {
  return {
    "Authorization": `Bearer ${GH_TOKEN}`,
    "Accept": "application/vnd.github+json",
    "Content-Type": "application/json",
    "User-Agent": "dbschemacheck-slack-approval",
    "X-GitHub-Api-Version": "2022-11-28",
  };
}

function bitbucketHeaders(): HeadersInit {
  const encoded = btoa(`${BITBUCKET_API_USERNAME}:${BITBUCKET_API_TOKEN}`);
  return {
    "Authorization": `Basic ${encoded}`,
    "Accept": "application/json",
    "Content-Type": "application/json",
  };
}

async function postJson(url: string, headers: HeadersInit, body?: unknown): Promise<HttpResult> {
  try {
    const res = await fetch(url, { method: "POST", headers, body: body === undefined ? undefined : JSON.stringify(body) });
    const detail = res.ok ? "" : cleanForSlack(await res.text(), 300);
    if (!res.ok) console.error(`POST ${url} -> ${res.status}: ${detail}`);
    return { ok: res.ok, status: res.status, detail, url };
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(`POST ${url} failed: ${detail}`);
    return { ok: false, status: 0, detail: cleanForSlack(detail, 300), url };
  }
}

async function deleteOptional(url: string, headers: HeadersInit): Promise<HttpResult> {
  try {
    const res = await fetch(url, { method: "DELETE", headers });
    if (res.ok || res.status === 400 || res.status === 404) {
      return { ok: true, status: res.status, detail: "", url };
    }

    const detail = cleanForSlack(await res.text(), 300);
    console.error(`DELETE ${url} -> ${res.status}: ${detail}`);
    return { ok: false, status: res.status, detail, url };
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(`DELETE ${url} failed: ${detail}`);
    return { ok: false, status: 0, detail: cleanForSlack(detail, 300), url };
  }
}

async function getJson(url: string, headers: HeadersInit): Promise<{ result: HttpResult; data?: Record<string, unknown> }> {
  try {
    const res = await fetch(url, { method: "GET", headers });
    const text = await res.text();
    if (!res.ok) {
      const detail = cleanForSlack(text, 300);
      console.error(`GET ${url} -> ${res.status}: ${detail}`);
      return { result: { ok: false, status: res.status, detail, url } };
    }
    return { result: { ok: true, status: res.status, detail: "", url }, data: JSON.parse(text) as Record<string, unknown> };
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(`GET ${url} failed: ${detail}`);
    return { result: { ok: false, status: 0, detail: cleanForSlack(detail, 300), url } };
  }
}

async function dispatchGitHubDecision(repo: string, decision: Decision, pr: string, sha: string, approver: string): Promise<HttpResult> {
  if (!GH_TOKEN) {
    return { ok: false, status: 0, detail: "GH_DISPATCH_TOKEN is not configured", url: "https://api.github.com" };
  }

  return await postJson(`https://api.github.com/repos/${repo}/dispatches`, githubHeaders(), {
    event_type: "schema-approval",
    client_payload: { decision, pr, sha, approver },
  });
}

async function applyBitbucketDecision(repo: string, decision: Decision, pr: string, sha: string): Promise<HttpResult> {
  if (!BITBUCKET_API_USERNAME || !BITBUCKET_API_TOKEN) {
    return { ok: false, status: 0, detail: "Bitbucket API credentials are not configured", url: "https://api.bitbucket.org" };
  }

  const [workspace, repoSlug] = repo.split("/");
  const baseUrl = `https://api.bitbucket.org/2.0/repositories/${workspace}/${repoSlug}/pullrequests/${pr}`;
  const headers = bitbucketHeaders();
  const current = await getJson(baseUrl, headers);
  if (!current.result.ok) return current.result;

  const source = current.data?.source as Record<string, unknown> | undefined;
  const commit = source?.commit as Record<string, unknown> | undefined;
  const currentHash = String(commit?.hash ?? "");
  if (currentHash.toLowerCase() !== sha.toLowerCase()) {
    return {
      ok: false,
      status: 409,
      detail: `PR head changed from ${sha.slice(0, 7)} to ${currentHash.slice(0, 7)}; rerun the schema check`,
      url: baseUrl,
    };
  }

  if (decision === "approve") {
    const clearChangeRequest = await deleteOptional(`${baseUrl}/request-changes`, headers);
    if (!clearChangeRequest.ok) return clearChangeRequest;
    return await postJson(`${baseUrl}/approve`, headers);
  }

  const clearApproval = await deleteOptional(`${baseUrl}/approve`, headers);
  if (!clearApproval.ok) return clearApproval;
  return await postJson(`${baseUrl}/request-changes`, headers);
}

async function updateSlackMessage(responseUrl: string, text: string) {
  if (!responseUrl) return;
  await fetch(responseUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ replace_original: true, text }),
  });
}

function failureMessage(userId: string, decisionText: string, provider: Provider, result: HttpResult, repo: string, sha: string): string {
  const statusText = result.status === 0 ? "network/configuration error" : `HTTP ${result.status}`;
  const detail = result.detail ? ` Response: \`${cleanForSlack(result.detail, 180)}\`` : "";
  return `:warning: <@${userId}> selected *${decisionText}*, but ${provider} could not be updated (${statusText}). Repo: \`${repo}\`, commit: \`${sha.slice(0, 7)}\`.${detail}`;
}

async function processDecision(payload: Record<string, unknown>) {
  const action = (payload.actions as Array<Record<string, unknown>> | undefined)?.[0];
  const decision = action?.action_id as Decision | undefined;
  const userId = (payload.user as Record<string, unknown> | undefined)?.id as string ?? "";
  const responseUrl = payload.response_url as string;

  if (decision !== "approve" && decision !== "reject") {
    await updateSlackMessage(responseUrl, `:warning: <@${userId}> Unknown schema approval decision. No gate state changed.`);
    return;
  }

  if (APPROVER_IDS.length > 0 && !APPROVER_IDS.includes(userId)) {
    await updateSlackMessage(responseUrl, `:no_entry: <@${userId}> You are not allowed to approve or reject this schema warning.`);
    return;
  }

  let meta: ButtonMeta;
  try {
    meta = JSON.parse((action?.value as string | undefined) ?? "{}") as ButtonMeta;
  } catch {
    await updateSlackMessage(responseUrl, `:warning: <@${userId}> Slack button metadata could not be parsed. No gate state changed.`);
    return;
  }

  const provider = meta.provider ?? "github";
  const repo = (meta.repo ?? "").trim();
  const sha = (meta.sha ?? "").trim();
  const pr = String(meta.pr ?? "").trim();

  const validProvider = provider === "github" || provider === "bitbucket";
  const validPullRequest = provider === "github" ? pr === "" || isValidPullRequestId(pr) : isValidPullRequestId(pr);
  if (!validProvider || !isValidRepo(repo) || !isValidSha(sha) || !validPullRequest) {
    await updateSlackMessage(responseUrl, `:warning: <@${userId}> Slack button metadata is invalid. No gate state changed. repo=\`${cleanForSlack(repo, 80)}\`, sha=\`${cleanForSlack(sha, 80)}\`, pr=\`${cleanForSlack(pr, 20)}\``);
    return;
  }

  const result = provider === "bitbucket"
    ? await applyBitbucketDecision(repo, decision, pr, sha)
    : await dispatchGitHubDecision(repo, decision, pr, sha, userId);

  const decisionText = decision === "approve" ? "Approve" : "Reject";
  if (!result.ok) {
    await updateSlackMessage(responseUrl, failureMessage(userId, decisionText, provider, result, repo, sha));
    return;
  }

  if (decision === "approve") {
    await updateSlackMessage(responseUrl, `:white_check_mark: <@${userId}> approved the schema warning. ${provider} has been updated for \`${repo}@${sha.slice(0, 7)}\`.`);
  } else {
    await updateSlackMessage(responseUrl, `:no_entry: <@${userId}> rejected the schema warning. ${provider} now requests changes for \`${repo}@${sha.slice(0, 7)}\`.`);
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const rawBody = await req.text();
  const ts = req.headers.get("x-slack-request-timestamp") ?? "";
  const sig = req.headers.get("x-slack-signature") ?? "";
  if (!verifySlackSignature(ts, sig, rawBody)) return new Response("invalid signature", { status: 401 });

  const payloadRaw = new URLSearchParams(rawBody).get("payload");
  if (!payloadRaw) return new Response("no payload", { status: 400 });
  const payload = JSON.parse(payloadRaw) as Record<string, unknown>;

  // @ts-ignore - EdgeRuntime global is provided by the Supabase Edge runtime.
  EdgeRuntime.waitUntil(processDecision(payload).catch((error) => console.error("processDecision failed", error)));
  return new Response("ok", { status: 200 });
});
