import net from "node:net";
import { LineBuffer } from "./line-buffer.js";

export interface PluginSocketOptions {
  port: number;
  label: string;
  host?: string;
  reconnectDelayMs?: number;
  onLine?: (line: string) => void;
  onConnect?: () => void;
  onDisconnect?: () => void;
  log?: (msg: string) => void;
}

export class PluginSocket {
  private socket: net.Socket | null = null;
  private connected = false;
  private readonly lines = new LineBuffer();
  private reconnectTimer: NodeJS.Timeout | null = null;
  private stopped = false;

  private readonly port: number;
  private readonly host: string;
  private readonly label: string;
  private readonly reconnectDelayMs: number;
  private readonly onLine?: (line: string) => void;
  private readonly onConnect?: () => void;
  private readonly onDisconnect?: () => void;
  private readonly log: (msg: string) => void;

  constructor(opts: PluginSocketOptions) {
    this.port = opts.port;
    this.label = opts.label;
    this.host = opts.host ?? "127.0.0.1";
    this.reconnectDelayMs = opts.reconnectDelayMs ?? 1000;
    this.onLine = opts.onLine;
    this.onConnect = opts.onConnect;
    this.onDisconnect = opts.onDisconnect;
    this.log = opts.log ?? ((msg: string) => console.error(msg));
  }

  connect(): void {
    if (this.stopped || this.socket) return;
    const sock = new net.Socket();
    sock.setEncoding("utf8");
    this.socket = sock;

    sock.on("connect", () => {
      this.connected = true;
      this.log(`[${this.label}] connected to ${this.host}:${this.port}`);
      this.onConnect?.();
    });

    sock.on("data", (chunk: string) => {
      if (this.onLine) this.lines.push(chunk, this.onLine);
    });

    sock.on("error", (err: NodeJS.ErrnoException) => {
      if (err.code !== "ECONNREFUSED") {
        this.log(`[${this.label}] error: ${err.message}`);
      }
    });

    sock.on("close", () => {
      const wasConnected = this.connected;
      this.connected = false;
      this.socket = null;
      this.lines.clear();
      if (wasConnected) this.log(`[${this.label}] disconnected, reconnecting`);
      if (wasConnected) this.onDisconnect?.();
      this.scheduleReconnect();
    });

    sock.connect(this.port, this.host);
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, this.reconnectDelayMs);
  }

  send(line: string): boolean {
    if (!this.socket || !this.connected) return false;
    this.socket.write(line + "\n");
    return true;
  }

  isConnected(): boolean {
    return this.connected;
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.socket) {
      this.socket.destroy();
      this.socket = null;
    }
    this.connected = false;
  }
}
