import { spawn } from "node:child_process";
import { once } from "node:events";
import { SERVER_BIN } from "./paths.mjs";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const DEFAULT_TOOL_TIMEOUT_MS = 120_000;
const READY_DEADLINE_MS = 30_000;

export class McpSession {
  constructor() {
    this.process = null;
    this.buffer = "";
    this.nextId = 1;
    this.pending = new Map();
  }

  async start() {
    this.process = spawn("node", [SERVER_BIN], { stdio: ["pipe", "pipe", "ignore"], env: { ...process.env, LIGHTROOM_MCP_TOOLSETS: "all" } });
    this.process.stdout.setEncoding("utf8");
    this.process.stdout.on("data", (chunk) => this.onStdout(chunk));
    this.process.on("exit", (code) => {
      for (const { reject } of this.pending.values()) reject(new Error(`server exited with code ${code}`));
      this.pending.clear();
    });
    await this.rpc("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "lightroom-mcp-live-kit", version: "0.0.0" },
    });
    this.send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
    await this.waitUntilPluginAnswers();
    return this;
  }

  async waitUntilPluginAnswers() {
    const deadline = Date.now() + READY_DEADLINE_MS;
    while (Date.now() < deadline) {
      try {
        const answer = await this.tool("list_collections", { limit: 1 }, { timeoutMs: 5000 });
        if (!answer.isError && !answer.text.includes("not connected")) return;
      } catch {
        await sleep(500);
      }
      await sleep(500);
    }
    throw new Error(`plugin did not answer within ${READY_DEADLINE_MS / 1000}s`);
  }

  onStdout(chunk) {
    this.buffer += chunk;
    let newline;
    while ((newline = this.buffer.indexOf("\n")) !== -1) {
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      if (message.method === "notifications/progress") {
        for (const waiter of this.pending.values()) {
          if (waiter.progressToken === message.params?.progressToken) waiter.onProgress?.(message.params);
        }
        continue;
      }
      const waiter = this.pending.get(message.id);
      if (!waiter) continue;
      this.pending.delete(message.id);
      if (message.error) waiter.reject(new Error(JSON.stringify(message.error)));
      else waiter.resolve(message.result);
    }
  }

  send(message) {
    this.process.stdin.write(JSON.stringify(message) + "\n");
  }

  rpc(method, params, timeoutMs = DEFAULT_TOOL_TIMEOUT_MS, { signal, onProgress, progressToken } = {}) {
    const id = this.nextId++;
    if (signal?.aborted) return Promise.reject(new Error("Request cancelled"));
    if (onProgress && progressToken === undefined) progressToken = `live-${id}`;
    if (progressToken !== undefined) params = { ...params, _meta: { ...params._meta, progressToken } };
    return new Promise((resolve, reject) => {
      const cancel = () => {
        if (!this.pending.has(id)) return;
        this.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: id, reason: "Live test cancellation" } });
        this.pending.get(id).reject(new Error("Request cancelled"));
        this.pending.delete(id);
      };
      const timer = setTimeout(() => {
        signal?.removeEventListener("abort", cancel);
        this.pending.delete(id);
        reject(new Error(`rpc timeout after ${timeoutMs} ms: ${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        progressToken, onProgress,
        resolve: (value) => {
          clearTimeout(timer);
          signal?.removeEventListener("abort", cancel);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          signal?.removeEventListener("abort", cancel);
          reject(error);
        },
      });
      signal?.addEventListener("abort", cancel, { once: true });
      this.send({ jsonrpc: "2.0", id, method, params });
    });
  }

  async tool(name, args = {}, { timeoutMs = DEFAULT_TOOL_TIMEOUT_MS, signal, onProgress, progressToken } = {}) {
    const startedAt = Date.now();
    const result = await this.rpc("tools/call", { name, arguments: args }, timeoutMs, { signal, onProgress, progressToken });
    const text = result?.content?.find((block) => block.type === "text")?.text ?? "";
    const image = result?.content?.find((block) => block.type === "image") ?? null;
    let data;
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
    return { isError: Boolean(result?.isError), text, data, image, ms: Date.now() - startedAt };
  }

  async toolOrThrow(name, args = {}, options = {}) {
    const answer = await this.tool(name, args, options);
    if (answer.isError) throw new Error(`${name}: ${answer.text}`);
    return answer;
  }

  async stop() {
    if (!this.process) return;
    this.process.stdin.end();
    await Promise.race([once(this.process, "exit"), sleep(2000)]);
    if (this.process.exitCode === null) this.process.kill("SIGKILL");
  }
}
