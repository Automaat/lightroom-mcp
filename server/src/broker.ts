/**
 * Local IPC between bridge processes. The plugin serves one client per port,
 * but MCP hosts spawn several bridges at once (Claude Desktop's chat plus its
 * Cowork/Code shared pool, issue 238). One bridge owns the plugin connection
 * and serves tool calls to the others over this channel.
 *
 * Both ends prove they can read the plugin token without sending it: the
 * follower opens with a challenge the owner must sign, and signs each call
 * over the owner's nonce. Whoever squats the socket or pipe name can neither
 * pose as the owner nor learn anything that unlocks the plugin.
 */
import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import type { ToolResponse } from "./tool-handler.js";

export type ToolCaller = (name: string, args: unknown) => Promise<ToolResponse>;

interface BrokerRequest {
  id: number;
  auth: string | null;
  name: string;
  args: unknown;
}

interface BrokerReply {
  id: number;
  result: ToolResponse;
}

/** macOS caps sun_path at 104 bytes, Linux at 108. */
const MAX_UNIX_SOCKET_PATH = 100;

/** Unterminated input past these sizes is a hostile or broken peer. */
const MAX_HANDSHAKE_BYTES = 1024;
export const MAX_FRAME_BYTES = 16 * 1024 * 1024;

export function brokerPath(
  requestPort: number,
  responsePort: number,
  baseDir = path.join(os.homedir(), ".config", "lightroom-mcp"),
  platform: NodeJS.Platform = process.platform,
): string {
  const name = `bridge-${requestPort}-${responsePort}`;
  if (platform === "win32") {
    return `\\\\.\\pipe\\lightroom-mcp-${os.userInfo().username}-${name}`;
  }
  const preferred = path.join(baseDir, `${name}.sock`);
  if (Buffer.byteLength(preferred) <= MAX_UNIX_SOCKET_PATH) return preferred;
  return path.join(os.tmpdir(), `lightroom-mcp-${os.userInfo().uid}-${name}.sock`);
}

export function signNonce(token: string | null, nonce: string): string | null {
  if (token === null) return null;
  return crypto.createHmac("sha256", token).update(nonce).digest("hex");
}

function newNonce(): string {
  return crypto.randomBytes(32).toString("hex");
}

function parseObject(line: string): Record<string, unknown> | null {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    return null;
  }
  return typeof raw === "object" && raw !== null && !Array.isArray(raw)
    ? (raw as Record<string, unknown>)
    : null;
}

function authMatches(expected: string | null, actual: string | null): boolean {
  if (expected === null || actual === null) return expected === actual;
  const a = Buffer.from(expected);
  const b = Buffer.from(actual);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function parseRequest(line: string): BrokerRequest | null {
  const req = parseObject(line);
  if (!req) return null;
  if (typeof req.id !== "number" || typeof req.name !== "string") return null;
  if (req.auth !== null && typeof req.auth !== "string") return null;
  return { id: req.id, auth: req.auth, name: req.name, args: req.args };
}

function errorResponse(text: string): ToolResponse {
  return { content: [{ type: "text", text }], isError: true };
}

function onLines(sock: net.Socket, handle: (line: string) => void, maxBytes: () => number): void {
  let buffer = "";
  sock.setEncoding("utf8");
  sock.on("data", (chunk: string) => {
    buffer += chunk;
    if (buffer.indexOf("\n") === -1 && Buffer.byteLength(buffer) > maxBytes()) {
      sock.destroy();
      return;
    }
    let idx: number;
    while ((idx = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, idx).trim();
      buffer = buffer.slice(idx + 1);
      if (line) handle(line);
    }
  });
}

export interface BrokerServerOptions {
  path: string;
  callTool: ToolCaller;
  readToken: () => string | null;
  log?: (msg: string) => void;
}

export class BrokerServer {
  private server: net.Server | null = null;
  private readonly clients = new Set<net.Socket>();
  private readonly log: (msg: string) => void;

  constructor(private readonly opts: BrokerServerOptions) {
    this.log = opts.log ?? ((msg: string) => console.error(msg));
  }

  /**
   * Only the instance-lock holder listens, so a leftover Unix socket file
   * belongs to a dead owner and is safe to remove first.
   */
  async listen(): Promise<void> {
    if (!this.opts.path.startsWith("\\\\")) {
      fs.rmSync(this.opts.path, { force: true });
    }
    const server = net.createServer((sock) => this.accept(sock));
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(this.opts.path, () => {
        server.off("error", reject);
        resolve();
      });
    });
    server.on("error", (err) => this.log(`[broker] server error: ${err.message}`));
    this.server = server;
  }

  private accept(sock: net.Socket): void {
    this.clients.add(sock);
    sock.on("error", () => {});
    sock.on("close", () => this.clients.delete(sock));
    const nonce = newNonce();
    let greeted = false;
    onLines(
      sock,
      (line) => {
        if (!greeted) {
          greeted = this.greet(sock, nonce, line);
          return;
        }
        this.handle(sock, nonce, line).catch((err: unknown) => {
          this.log(`[broker] failed to serve a follower call: ${String(err)}`);
        });
      },
      () => (greeted ? MAX_FRAME_BYTES : MAX_HANDSHAKE_BYTES),
    );
  }

  private greet(sock: net.Socket, nonce: string, line: string): boolean {
    const challenge = parseObject(line)?.challenge;
    if (typeof challenge !== "string") {
      this.log("[broker] follower opened without a challenge, dropping it");
      sock.destroy();
      return false;
    }
    const proof = signNonce(this.opts.readToken(), `owner:${challenge}`);
    sock.write(JSON.stringify({ nonce, proof }) + "\n");
    return true;
  }

  private async handle(sock: net.Socket, nonce: string, line: string): Promise<void> {
    const req = parseRequest(line);
    if (!req) {
      this.log(`[broker] malformed request from follower: ${line.slice(0, 200)}`);
      return;
    }
    const result = authMatches(signNonce(this.opts.readToken(), `follower:${nonce}`), req.auth)
      ? await this.opts.callTool(req.name, req.args)
      : errorResponse("Rejected by the Lightroom MCP bridge: token mismatch.");
    if (sock.destroyed) return;
    const reply: BrokerReply = { id: req.id, result };
    sock.write(JSON.stringify(reply) + "\n");
  }

  close(): void {
    for (const sock of this.clients) sock.destroy();
    this.clients.clear();
    this.server?.close();
    this.server = null;
  }
}

export const OWNER_LOST_MESSAGE =
  "The Lightroom MCP process that owned the plugin connection exited during this call, " +
  "so its result is unknown. Check Lightroom before retrying a call that changes photos.";

export interface BrokerClientOptions {
  path: string;
  readToken: () => string | null;
  onClose?: () => void;
  helloTimeoutMs?: number;
}

export class BrokerClient {
  private sock: net.Socket | null = null;
  private nonce = "";
  private nextId = 0;
  private readonly pending = new Map<number, (resp: ToolResponse) => void>();

  constructor(private readonly opts: BrokerClientOptions) {}

  /**
   * Resolves once the owner has proven it can read the plugin token; rejects
   * on a bad proof, a hang-up, or no greeting in time.
   */
  async connect(): Promise<void> {
    const sock = net.createConnection(this.opts.path);
    const challenge = newNonce();
    let greeted: (hello: Record<string, unknown>) => void = () => {};
    const hello = new Promise<Record<string, unknown>>((resolve) => (greeted = resolve));
    onLines(sock, (line) => this.receive(line, greeted), () => MAX_FRAME_BYTES);
    try {
      const greeting = await new Promise<Record<string, unknown>>((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error("owning bridge did not greet")),
          this.opts.helloTimeoutMs ?? 2_000,
        );
        sock.once("error", reject);
        sock.once("close", () => reject(new Error("owning bridge closed the connection")));
        sock.once("connect", () => sock.write(JSON.stringify({ challenge }) + "\n"));
        void hello.then((msg) => {
          clearTimeout(timer);
          resolve(msg);
        });
      });
      const proof = typeof greeting.proof === "string" ? greeting.proof : null;
      if (!authMatches(signNonce(this.opts.readToken(), `owner:${challenge}`), proof)) {
        throw new Error("owning bridge could not prove it holds the plugin token");
      }
      this.nonce = greeting.nonce as string;
    } catch (err) {
      sock.destroy();
      throw err;
    }
    sock.removeAllListeners("error");
    sock.removeAllListeners("close");
    sock.on("error", () => {});
    sock.on("close", () => {
      this.sock = null;
      for (const resolve of this.pending.values()) resolve(errorResponse(OWNER_LOST_MESSAGE));
      this.pending.clear();
      this.opts.onClose?.();
    });
    this.sock = sock;
  }

  private receive(line: string, greeted: (hello: Record<string, unknown>) => void): void {
    const data = parseObject(line);
    if (!data) return;
    if (typeof data.nonce === "string") {
      greeted(data);
      return;
    }
    if (typeof data.id !== "number") return;
    const resolve = this.pending.get(data.id);
    this.pending.delete(data.id);
    resolve?.((data as unknown as BrokerReply).result);
  }

  isConnected(): boolean {
    return this.sock !== null;
  }

  callTool(name: string, args: unknown): Promise<ToolResponse> {
    const sock = this.sock;
    if (!sock) return Promise.resolve(errorResponse(OWNER_LOST_MESSAGE));
    const id = this.nextId++;
    const req: BrokerRequest = {
      id,
      auth: signNonce(this.opts.readToken(), `follower:${this.nonce}`),
      name,
      args,
    };
    return new Promise((resolve) => {
      this.pending.set(id, resolve);
      sock.write(JSON.stringify(req) + "\n");
    });
  }

  close(): void {
    this.sock?.destroy();
  }
}
