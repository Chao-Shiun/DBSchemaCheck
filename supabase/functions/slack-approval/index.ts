// Supabase Edge Function: Slack interactivity endpoint for schema-gate approvals.
//
// Bitbucket is the default path and applies the Slack decision directly as the configured bot reviewer:
// approve clears the bot's change request and approves the PR; reject declines the PR.
// GitHub mode keeps the original repository_dispatch flow only when provider=github is explicit.
import { createHmac } from "node:crypto";

const SLACK_SIGNING_SECRET = Deno.env.get("SLACK_SIGNING_SECRET") ?? "";
const GH_TOKEN = Deno.env.get("GH_DISPATCH_TOKEN") ?? "";
const BITBUCKET_API_USERNAME = Deno.env.get("BITBUCKET_API_USERNAME") ?? "";
const BITBUCKET_API_TOKEN = Deno.env.get("BITBUCKET_API_TOKEN") ?? "";
const APPROVER_IDS = (Deno.env.get("APPROVER_SLACK_IDS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
const DEFAULT_PROVIDER = parseProvider(Deno.env.get("DEFAULT_SCM_PROVIDER")) ?? "bitbucket";

type Decision = "approve" | "reject";
type Provider = "github" | "bitbucket";

type ButtonMeta = {
  provider?: string;
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

function isValidCommitHash(hash: string): boolean {
  return /^[0-9a-f]{7,40}$/i.test(hash);
}

function isValidPullRequestId(pr: string): boolean {
  return /^[0-9]+$/.test(pr);
}

function cleanForSlack(text: string, maxLength: number): string {
  return text.replace(/[`<>]/g, "").slice(0, maxLength);
}

function parseProvider(value: unknown): Provider | undefined {
  return value === "github" || value === "bitbucket" ? value : undefined;
}

function resolveProvider(meta: ButtonMeta, pr: string): Provider {
  const explicitProvider = parseProvider(meta.provider);
  if (explicitProvider) return explicitProvider;

  // Bitbucket pull request actions require a PR id, so old messages that carry one should stay on Bitbucket.
  if (isValidPullRequestId(pr)) return "bitbucket";

  return DEFAULT_PROVIDER;
}

function providerLabel(provider: Provider): string {
  return provider === "bitbucket" ? "Bitbucket" : "GitHub";
}

function shortHash(hash: string): string {
  return hash ? hash.slice(0, 12) : "unknown";
}

function commitHashesMatch(expected: string, actual: string): boolean {
  const normalizedExpected = expected.toLowerCase();
  const normalizedActual = actual.toLowerCase();
  if (normalizedExpected === normalizedActual) return true;
  if (!isValidCommitHash(normalizedExpected) || !isValidCommitHash(normalizedActual)) return false;

  const shortestLength = Math.min(normalizedExpected.length, normalizedActual.length);
  return shortestLength >= 7 && (normalizedExpected.startsWith(normalizedActual) || normalizedActual.startsWith(normalizedExpected));
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
  };
}

function formatHttpErrorDetail(text: string): string {
  try {
    const parsed = JSON.parse(text) as Record<string, unknown>;
    const error = parsed.error as Record<string, unknown> | undefined;
    const message = String(error?.message ?? parsed.message ?? text);
    const detail = String(error?.detail ?? "");
    return cleanForSlack(detail ? `${message}: ${detail}` : message, 300);
  } catch {
    return cleanForSlack(text, 300);
  }
}

async function postJson(url: string, headers: HeadersInit, body?: unknown): Promise<HttpResult> {
  try {
    const res = await fetch(url, { method: "POST", headers, body: body === undefined ? undefined : JSON.stringify(body) });
    const detail = res.ok ? "" : formatHttpErrorDetail(await res.text());
    if (!res.ok) console.error(`POST ${url} -> ${res.status}: ${detail}`);
    return { ok: res.ok, status: res.status, detail, url };
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(`POST ${url} failed: ${detail}`);
    return { ok: false, status: 0, detail: cleanForSlack(detail, 300), url };
  }
}

async function postDecision(url: string, headers: HeadersInit, alreadySetMessage: string): Promise<HttpResult> {
  const result = await postJson(url, headers);
  if (result.ok || result.status !== 400) return result;

  return { ok: true, status: result.status, detail: alreadySetMessage, url: result.url };
}

async function deleteOptional(url: string, headers: HeadersInit): Promise<HttpResult> {
  try {
    const res = await fetch(url, { method: "DELETE", headers });
    if (res.ok || res.status === 400 || res.status === 404) {
      return { ok: true, status: res.status, detail: "", url };
    }

    const detail = formatHttpErrorDetail(await res.text());
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
      const detail = formatHttpErrorDetail(text);
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
    return { ok: false, status: 0, detail: "BITBUCKET_API_USERNAME or BITBUCKET_API_TOKEN is not configured", url: "https://api.bitbucket.org" };
  }

  const [workspace, repoSlug] = repo.split("/");
  const baseUrl = `https://api.bitbucket.org/2.0/repositories/${workspace}/${repoSlug}/pullrequests/${pr}`;
  const headers = bitbucketHeaders();
  const current = await getJson(baseUrl, headers);
  if (!current.result.ok) return current.result;

  const source = current.data?.source as Record<string, unknown> | undefined;
  const commit = source?.commit as Record<string, unknown> | undefined;
  const state = String(current.data?.state ?? "");
  const currentHash = String(commit?.hash ?? "");
  if (!commitHashesMatch(sha, currentHash)) {
    return {
      ok: false,
      status: 409,
      detail: `PR head changed from ${shortHash(sha)} to ${shortHash(currentHash)}; rerun the schema check`,
      url: baseUrl,
    };
  }

  if (state && state !== "OPEN") {
    if (decision === "reject" && state === "DECLINED") {
      return { ok: true, status: 200, detail: "Bitbucket already declined this PR", url: baseUrl };
    }

    return {
      ok: false,
      status: 409,
      detail: `PR is ${state.toLowerCase()}; no schema gate decision was changed`,
      url: baseUrl,
    };
  }

  if (decision === "approve") {
    const clearChangeRequest = await deleteOptional(`${baseUrl}/request-changes`, headers);
    if (!clearChangeRequest.ok) return clearChangeRequest;
    return await postDecision(`${baseUrl}/approve`, headers, "Bitbucket already has this approval decision");
  }

  const clearApproval = await deleteOptional(`${baseUrl}/approve`, headers);
  if (!clearApproval.ok) return clearApproval;
  const clearChangeRequest = await deleteOptional(`${baseUrl}/request-changes`, headers);
  if (!clearChangeRequest.ok) return clearChangeRequest;
  return await postJson(`${baseUrl}/decline`, headers);
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
  return `:warning: <@${userId}> selected *${decisionText}*, but ${providerLabel(provider)} could not be updated (${statusText}). Repo: \`${repo}\`, commit: \`${sha.slice(0, 7)}\`.${detail}`;
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

  const repo = (meta.repo ?? "").trim();
  const sha = (meta.sha ?? "").trim();
  const pr = String(meta.pr ?? "").trim();
  const provider = resolveProvider(meta, pr);

  const validPullRequest = provider === "github" ? pr === "" || isValidPullRequestId(pr) : isValidPullRequestId(pr);
  if (!isValidRepo(repo) || !isValidSha(sha) || !validPullRequest) {
    await updateSlackMessage(responseUrl, `:warning: <@${userId}> Slack button metadata is invalid. No gate state changed. provider=\`${provider}\`, repo=\`${cleanForSlack(repo, 80)}\`, sha=\`${cleanForSlack(sha, 80)}\`, pr=\`${cleanForSlack(pr, 20)}\``);
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
    await updateSlackMessage(responseUrl, `:white_check_mark: <@${userId}> approved the schema warning. ${providerLabel(provider)} has been updated for \`${repo}@${sha.slice(0, 7)}\`.`);
  } else {
    await updateSlackMessage(responseUrl, `:no_entry: <@${userId}> rejected the schema warning. ${providerLabel(provider)} declined PR #${pr} for \`${repo}@${sha.slice(0, 7)}\`.`);
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
