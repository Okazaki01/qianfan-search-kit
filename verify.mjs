#!/usr/bin/env node
/**
 * qianfan-search MCP server 自检 —— 零依赖（只用 Node 标准库）。
 *
 * 用最小 JSON-RPC 客户端跑一遍真实协议流程，确认：
 *   1) 服务能起来并完成 initialize 握手
 *   2) tools/list 能列出 baidu_search 且参数 schema 完整
 *   3) 传空参数时正确返回 isError（不消耗额度）
 *   4) 可选：--call "<关键词>" 做一次真实搜索（会消耗 1 次额度）
 *
 * 用法：
 *   node verify.mjs                          # 只做 1~3（不联网、不耗额度）
 *   node verify.mjs --call "今天的新闻"       # 再做一次真实搜索
 *   node verify.mjs --server <server.mjs 路径> --node <node 可执行文件>
 *
 * 退出码：0 全部通过；1 有失败。
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const SERVER = resolve(arg("--server", join(HERE, "payload", "skills", "qianfan-search", "mcp", "server.mjs")));
const NODE = arg("--node", process.execPath);
const CALL_QUERY = arg("--call", null);
const TIMEOUT_MS = Number(arg("--timeout", "30000"));

const pass = [];
const fail = [];
function ok(msg) {
  pass.push(msg);
  console.log("  ✅ " + msg);
}
function bad(msg) {
  fail.push(msg);
  console.log("  ❌ " + msg);
}

console.log("qianfan-search MCP 自检");
console.log("  node   :", NODE);
console.log("  server :", SERVER);
if (!existsSync(SERVER)) {
  console.error(`\n致命：找不到 server.mjs：${SERVER}`);
  process.exit(1);
}

const child = spawn(NODE, [SERVER], { stdio: ["pipe", "pipe", "pipe"] });
const pending = new Map();
let nextId = 1;
let stderrTail = [];

child.stderr.on("data", (d) => {
  const s = String(d).trim();
  if (s) {
    stderrTail.push(s);
    if (stderrTail.length > 10) stderrTail.shift();
  }
});
child.on("exit", (code, sig) => {
  if (pending.size > 0) {
    for (const [, p] of pending) p.reject(new Error(`服务提前退出（code=${code} sig=${sig}）`));
  }
});

let buffer = "";
child.stdout.on("data", (chunk) => {
  buffer += chunk;
  let i;
  while ((i = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, i).trim();
    buffer = buffer.slice(i + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    if (msg.id !== undefined && pending.has(msg.id)) {
      const p = pending.get(msg.id);
      pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new Error(`${msg.error.code}: ${msg.error.message}`));
      else p.resolve(msg.result);
    }
  }
});

function rpc(method, params) {
  const id = nextId++;
  const payload = { jsonrpc: "2.0", id, method };
  if (params !== undefined) payload.params = params;
  return new Promise((resolvePromise, rejectPromise) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      rejectPromise(new Error(`「${method}」超时（${TIMEOUT_MS}ms）`));
    }, TIMEOUT_MS);
    pending.set(id, { resolve: resolvePromise, reject: rejectPromise, timer });
    child.stdin.write(JSON.stringify(payload) + "\n");
  });
}

function notify(method, params) {
  const payload = { jsonrpc: "2.0", method };
  if (params !== undefined) payload.params = params;
  child.stdin.write(JSON.stringify(payload) + "\n");
}

console.log("\n1) initialize 握手…");
let serverInfo;
try {
  const result = await rpc("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "qianfan-verify", version: "1.0.0" },
  });
  serverInfo = result.serverInfo;
  notify("notifications/initialized");
  ok(`握手成功：serverInfo=${JSON.stringify(result.serverInfo)} protocolVersion=${result.protocolVersion}`);
  if (result.capabilities?.tools) ok("capabilities.tools 已声明");
  else bad("capabilities.tools 缺失");
} catch (e) {
  bad("握手失败：" + e.message);
}

if (serverInfo) {
  console.log("\n2) tools/list…");
  try {
    const { tools } = await rpc("tools/list", {});
    const tool = (tools ?? []).find((t) => t.name === "baidu_search");
    if (tool) {
      ok(`列出 ${tools.length} 个工具，含 baidu_search`);
      const props = Object.keys(tool.inputSchema?.properties ?? {});
      ok(`参数：${props.join(", ")}`);
      if (tool.description) ok("工具描述非空（模型能看到）");
      else bad("工具描述为空");
    } else {
      bad(`没找到 baidu_search，实际为：${(tools ?? []).map((t) => t.name).join(", ") || "(空)"}`);
    }
  } catch (e) {
    bad("tools/list 失败：" + e.message);
  }

  console.log("\n3) tools/call 错误路径（空参数，不消耗额度）…");
  try {
    const r = await rpc("tools/call", { name: "baidu_search", arguments: {} });
    const text = r.content?.[0]?.text ?? "";
    if (r.isError === true && text) ok(`正确返回 isError=true：${text.slice(0, 60)}`);
    else bad(`期望 isError=true，实际 isError=${r.isError} text=${text.slice(0, 60)}`);
  } catch (e) {
    bad("tools/call 错误路径异常：" + e.message);
  }
}

if (CALL_QUERY) {
  console.log(`\n4) 真实搜索「${CALL_QUERY}」（消耗 1 次额度）…`);
  try {
    const r = await rpc("tools/call", {
      name: "baidu_search",
      arguments: { query: CALL_QUERY, top_k: 2, max_chars: 300 },
    });
    const text = r.content?.[0]?.text ?? "";
    if (r.isError === false && text) {
      ok("搜索成功，返回内容如下：");
      console.log(text.split("\n").map((l) => "      " + l).join("\n"));
    } else {
      bad(`搜索失败（isError=${r.isError}）：${text.slice(0, 200)}`);
    }
  } catch (e) {
    bad("真实搜索异常：" + e.message);
  }
} else {
  console.log("\n4) 跳过真实搜索（要跑就加 --call \"关键词\"）");
}

child.stdin.end();
setTimeout(() => child.kill(), 300);

console.log(`\n结果：通过 ${pass.length} 项，失败 ${fail.length} 项`);
if (fail.length > 0) {
  if (stderrTail.length) console.log("\n服务端最后输出：\n  " + stderrTail.join("\n  "));
  process.exit(1);
}
console.log("自检通过 ✅");
