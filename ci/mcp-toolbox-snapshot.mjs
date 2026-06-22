#!/usr/bin/env node
import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";

const toolboxPath = process.argv[2];
const outputPath = process.argv[3] ?? "ci/live-schema.json";

if (!toolboxPath) {
  console.error("Usage: node ci/mcp-toolbox-snapshot.mjs <toolbox-path> [output-path]");
  process.exit(2);
}

const requiredEnv = ["POSTGRES_DATABASE", "POSTGRES_USER", "POSTGRES_PASSWORD"];
const missingEnv = requiredEnv.filter(name => !process.env[name]);

if (missingEnv.length > 0) {
  console.error(`Missing required PostgreSQL environment variables: ${missingEnv.join(", ")}`);
  process.exit(2);
}

let nextId = 1;
let stdoutBuffer = Buffer.alloc(0);
let stderrText = "";
const pending = new Map();
const toolboxArgs = ["--prebuilt", "postgres", "--stdio"];
const child = spawn(toolboxPath, toolboxArgs, { env: process.env, stdio: ["pipe", "pipe", "pipe"] });

child.on("error", error => {
  for (const { reject, timer } of pending.values()) {
    clearTimeout(timer);
    reject(error);
  }
  pending.clear();
});

child.stderr.on("data", data => {
  stderrText = `${stderrText}${data.toString("utf8")}`;
});

child.on("exit", (code, signal) => {
  for (const { reject, timer } of pending.values()) {
    clearTimeout(timer);
    reject(new Error(`toolbox exited before responding, code=${code ?? "-"}, signal=${signal ?? "-"}`));
  }
  pending.clear();
});

child.stdout.on("data", data => {
  stdoutBuffer = Buffer.concat([stdoutBuffer, data]);
  drainMessages();
});

function drainMessages() {
  while (true) {
    if (stdoutBuffer.length === 0) {
      return;
    }

    if (!stdoutBuffer.toString("utf8", 0, Math.min(stdoutBuffer.length, 15)).startsWith("Content-Length:")) {
      const newline = stdoutBuffer.indexOf("\n");
      if (newline < 0) {
        return;
      }

      const line = stdoutBuffer.subarray(0, newline).toString("utf8").trim();
      stdoutBuffer = stdoutBuffer.subarray(newline + 1);
      if (line.length === 0) {
        continue;
      }

      const message = JSON.parse(line);
      handleMessage(message);
      continue;
    }

    const separator = stdoutBuffer.indexOf("\r\n\r\n");
    if (separator < 0) {
      return;
    }

    const header = stdoutBuffer.subarray(0, separator).toString("utf8");
    const lengthMatch = /Content-Length:\s*(\d+)/i.exec(header);
    if (!lengthMatch) {
      throw new Error(`Invalid MCP frame header: ${header}`);
    }

    const contentLength = Number(lengthMatch[1]);
    const bodyStart = separator + 4;
    const bodyEnd = bodyStart + contentLength;
    if (stdoutBuffer.length < bodyEnd) {
      return;
    }

    const body = stdoutBuffer.subarray(bodyStart, bodyEnd).toString("utf8");
    stdoutBuffer = stdoutBuffer.subarray(bodyEnd);
    const message = JSON.parse(body);
    handleMessage(message);
  }
}

function handleMessage(message) {
  if (message.id === undefined || !pending.has(message.id)) {
    return;
  }

  const entry = pending.get(message.id);
  pending.delete(message.id);
  clearTimeout(entry.timer);

  if (message.error) {
    entry.reject(new Error(`${message.error.message ?? "MCP request failed"} (${JSON.stringify(message.error)})`));
    return;
  }

  entry.resolve(message.result ?? {});
}

function sendMessage(message) {
  child.stdin.write(`${JSON.stringify(message)}\n`);
}

function request(method, params = {}, timeoutMs = 30000) {
  const id = nextId++;
  const timer = setTimeout(() => {
    const pendingRequest = pending.get(id);
    if (!pendingRequest) {
      return;
    }

    pending.delete(id);
    const detail = stderrText.trim().slice(-2000);
    const error = detail ? `MCP request ${method} timed out, id=${id}. toolbox stderr: ${detail}` : `MCP request ${method} timed out, id=${id}.`;
    pendingRequest.reject(new Error(error));
  }, timeoutMs);

  const promise = new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject, timer });
  });

  sendMessage({ jsonrpc: "2.0", id, method, params });
  return promise;
}

function notify(method, params = {}) {
  sendMessage({ jsonrpc: "2.0", method, params });
}

function findTool(tools, candidates) {
  const names = new Set(tools.map(tool => tool.name));
  return candidates.find(candidate => names.has(candidate)) ?? null;
}

async function callTool(toolName, args = {}) {
  return request("tools/call", { name: toolName, arguments: args }, 60000);
}

async function callFirstAvailable(tools, label, candidates, argVariants = [{}]) {
  const toolName = findTool(tools, candidates);
  if (!toolName) {
    return { ok: false, label, candidates, error: "No matching MCP Toolbox tool was exposed." };
  }

  const errors = [];
  for (const args of argVariants) {
    try {
      const result = await callTool(toolName, args);
      return { ok: true, label, toolName, arguments: args, result };
    } catch (error) {
      errors.push({ arguments: args, error: error.message });
    }
  }

  return { ok: false, label, toolName, errors };
}

async function main() {
  await request("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "dbschemacheck-ci", version: "1.0.0" }
  });
  notify("notifications/initialized");

  const toolsResponse = await request("tools/list", {}, 30000);
  const tools = Array.isArray(toolsResponse.tools) ? toolsResponse.tools : [];

  if (tools.length === 0) {
    throw new Error("MCP Toolbox returned zero tools from tools/list.");
  }

  const metadataSql = `
select
  c.table_schema,
  c.table_name,
  c.ordinal_position,
  c.column_name,
  c.data_type,
  c.udt_name,
  c.is_nullable,
  c.column_default,
  c.character_maximum_length,
  c.numeric_precision,
  c.numeric_scale
from information_schema.columns c
where c.table_schema not in ('pg_catalog', 'information_schema')
order by c.table_schema, c.table_name, c.ordinal_position
limit 1000`;

  const calls = {
    listSchemas: await callFirstAvailable(tools, "listSchemas", ["list_schemas", "postgres_list_schemas", "postgres-list-schemas"]),
    listTables: await callFirstAvailable(tools, "listTables", ["list_tables", "postgres_list_tables", "postgres-list-tables"], [{ output_format: "detailed" }, {}]),
    listIndexes: await callFirstAvailable(tools, "listIndexes", ["list_indexes", "postgres_list_indexes", "postgres-list-indexes"], [{ limit: 200 }, {}]),
    listViews: await callFirstAvailable(tools, "listViews", ["list_views", "postgres_list_views", "postgres-list-views"], [{ limit: 100 }, {}]),
    metadataColumns: await callFirstAvailable(tools, "metadataColumns", ["execute_sql", "postgres_execute_sql", "postgres-execute-sql", "sql", "postgres_sql", "postgres-sql"], [{ sql: metadataSql }])
  };

  const hasTableEvidence = calls.listTables.ok || calls.metadataColumns.ok;
  const snapshot = {
    generatedAt: new Date().toISOString(),
    source: "MCP Toolbox for Databases",
    toolbox: {
      command: toolboxPath,
      args: toolboxArgs,
      version: process.env.TOOLBOX_VERSION ?? "unknown"
    },
    postgres: {
      host: process.env.POSTGRES_HOST ?? "",
      port: process.env.POSTGRES_PORT ?? "",
      database: process.env.POSTGRES_DATABASE ?? "",
      user: process.env.POSTGRES_USER ?? "",
      queryParams: process.env.POSTGRES_QUERY_PARAMS ?? ""
    },
    tools: tools.map(tool => ({ name: tool.name, description: tool.description ?? "" })),
    calls
  };

  await writeFile(outputPath, JSON.stringify(snapshot, null, 2));

  if (!hasTableEvidence) {
    throw new Error(`MCP Toolbox connected but did not return table evidence. Snapshot written to ${outputPath}.`);
  }

  const okCalls = Object.values(calls).filter(call => call.ok).length;
  console.log(`MCP Toolbox live schema snapshot saved to ${outputPath}; tools=${tools.length}; successfulCalls=${okCalls}.`);
}

try {
  await main();
  child.stdin.end();
  child.kill();
} catch (error) {
  child.kill();
  const detail = stderrText.trim().slice(-2000);
  if (detail) {
    console.error(`toolbox stderr: ${detail}`);
  }
  console.error(`MCP Toolbox live schema snapshot failed: ${error.message}`);
  process.exit(1);
}
