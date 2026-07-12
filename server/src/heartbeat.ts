// Extracted from index.ts so the ping-interval wiring can be unit tested in
// isolation, without booting the real MCP server / sockets that main() sets
// up. See tests/heartbeat.test.ts.
//
// Heartbeat: ping the plugin on this interval so it can tell a healthy-but-
// idle session apart from a genuinely dead connection (issue #134 follow-up,
// PR #151 review) instead of relying on a long fixed idle timer. The plugin
// derives liveness from any inbound message -- ping included -- via its
// existing lastRequestTime tracking, so this side doesn't need to react to a
// missed pong itself; a failed/timed-out ping is only logged for visibility.

export interface HeartbeatDispatcher {
  call(action: string, params: unknown): Promise<unknown>;
}

/**
 * Starts a fire-and-forget ping loop against the dispatcher and returns the
 * timer handle so the caller can clearInterval() it (e.g. on shutdown).
 * dispatcher.call() rejects on its own if the request socket is currently
 * disconnected, so this is safe to run unconditionally regardless of
 * connection state -- a failed ping is just logged via onError, never thrown.
 */
export function startHeartbeat(
  dispatcher: HeartbeatDispatcher,
  intervalMs: number,
  onError: (err: Error) => void = (err) => console.error(`[heartbeat] ping failed: ${err.message}`),
): NodeJS.Timeout {
  return setInterval(() => {
    dispatcher.call("ping", {}).catch((err: Error) => {
      onError(err);
    });
  }, intervalMs);
}