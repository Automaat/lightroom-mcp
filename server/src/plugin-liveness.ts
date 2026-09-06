/**
 * Whether the plugin is actually answering, as opposed to merely accepting TCP
 * connections.
 *
 * The plugin serves one client per port. A second bridge still connects
 * successfully -- the kernel accepts, the plugin never reads -- so socket state
 * alone reports "ready" while every request sits unanswered until it times out
 * (issue 215). Pings settle that question, so readiness follows the pings:
 *
 *   unknown      no ping has settled yet. A tool call waits for the in-flight
 *                probe rather than racing it, so no call is ever dispatched
 *                into a connection nobody is reading.
 *   responsive   a ping came back.
 *   unresponsive a ping timed out. Tool calls fail immediately with an
 *                explanation instead of burning the full request timeout each.
 */
export type PluginLivenessState = "unknown" | "responsive" | "unresponsive";

export const SHADOW_BRIDGE_MESSAGE =
  "Connected to the Lightroom plugin's ports, but it is not answering. " +
  "The plugin serves one client at a time, so another lightroom-mcp process " +
  "is most likely holding the connection. Quit any other MCP client or stale " +
  "bridge process (pgrep -fl lightroom-mcp), or restart the plugin from " +
  "Lightroom's Plug-in Manager.";

export class PluginLiveness {
  private state: PluginLivenessState = "unknown";
  private pending: Promise<void> | null = null;
  private resolvePending: (() => void) | null = null;

  markResponsive(): void {
    this.state = "responsive";
    this.release();
  }

  markUnresponsive(): void {
    this.state = "unresponsive";
    this.release();
  }

  reset(): void {
    this.state = "unknown";
    this.release();
  }

  /** Marks a probe as in flight so callers can await its verdict. */
  beginProbe(): void {
    if (this.pending) return;
    this.pending = new Promise<void>((resolve) => {
      this.resolvePending = resolve;
    });
  }

  /**
   * Resolves once the current probe has settled. Returns immediately when the
   * state is already known or no probe is running.
   */
  async settled(): Promise<void> {
    if (this.state !== "unknown" || !this.pending) return;
    await this.pending;
  }

  current(): PluginLivenessState {
    return this.state;
  }

  isUsable(): boolean {
    return this.state !== "unresponsive";
  }

  private release(): void {
    const resolve = this.resolvePending;
    this.pending = null;
    this.resolvePending = null;
    resolve?.();
  }
}
