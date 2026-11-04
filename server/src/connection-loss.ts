/**
 * Runs `onExpired` once a lost plugin connection has stayed down for `ms`.
 * Answers to calls sent before a loss never arrive, so they fail here instead
 * of waiting for their full timeout.
 */
export class ConnectionLossDeadline {
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly ms: number,
    private readonly onExpired: () => void,
  ) {}

  start(): void {
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.onExpired();
    }, this.ms);
  }

  clear(): void {
    if (!this.timer) return;
    clearTimeout(this.timer);
    this.timer = null;
  }
}
