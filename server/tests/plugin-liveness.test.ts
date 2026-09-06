import { describe, it, expect, jest } from '@jest/globals';
import { PluginLiveness, SHADOW_BRIDGE_MESSAGE } from '../src/plugin-liveness.js';
import { probePlugin, type HeartbeatDispatcher } from '../src/heartbeat.js';
import { createCallToolHandler } from '../src/tool-handler.js';

describe('PluginLiveness', () => {
  it('treats a connection with no settled ping as usable', () => {
    const liveness = new PluginLiveness();

    expect(liveness.current()).toBe('unknown');
    expect(liveness.isUsable()).toBe(true);
  });

  it('becomes unusable once a ping fails and usable again once one succeeds', () => {
    const liveness = new PluginLiveness();

    liveness.markUnresponsive();
    expect(liveness.isUsable()).toBe(false);

    liveness.markResponsive();
    expect(liveness.isUsable()).toBe(true);
  });

  it('makes callers wait for an in-flight probe instead of racing it', async () => {
    const liveness = new PluginLiveness();
    liveness.beginProbe();

    let settled = false;
    const waiter = liveness.settled().then(() => {
      settled = true;
    });

    await Promise.resolve();
    expect(settled).toBe(false);

    liveness.markUnresponsive();
    await waiter;

    expect(settled).toBe(true);
    expect(liveness.isUsable()).toBe(false);
  });

  it('keeps the first probe when beginProbe is called again', async () => {
    const liveness = new PluginLiveness();
    liveness.beginProbe();
    liveness.beginProbe();

    let settled = false;
    const waiter = liveness.settled().then(() => { settled = true; });
    await Promise.resolve();
    expect(settled).toBe(false);

    liveness.markResponsive();
    await waiter;
    expect(settled).toBe(true);
  });

  it('does not block when no probe is in flight', async () => {
    const liveness = new PluginLiveness();

    await expect(liveness.settled()).resolves.toBeUndefined();
  });

  it('returns to unknown on reset, so a reconnect starts optimistic', () => {
    const liveness = new PluginLiveness();
    liveness.markUnresponsive();

    liveness.reset();

    expect(liveness.current()).toBe('unknown');
    expect(liveness.isUsable()).toBe(true);
  });
});

describe('probePlugin', () => {
  it('reports true when the plugin answers', async () => {
    const dispatcher: HeartbeatDispatcher = {
      call: jest.fn(() => Promise.resolve({ pong: true })),
    };

    await expect(probePlugin(dispatcher, 5_000)).resolves.toBe(true);
    expect(dispatcher.call).toHaveBeenCalledWith('ping', {}, 5_000);
  });

  it('reports false when the ping times out instead of throwing', async () => {
    const dispatcher: HeartbeatDispatcher = {
      call: jest.fn(() => Promise.reject(new Error('Plugin response timeout (10s)'))),
    };

    await expect(probePlugin(dispatcher)).resolves.toBe(false);
  });
});

describe('tool handler readiness message', () => {
  const dispatcher = { call: jest.fn(() => Promise.resolve({ id: 'req_1', result: {} })) };

  it('explains that another bridge owns the plugin when sockets are up but silent', async () => {
    const handler = createCallToolHandler({
      dispatcher,
      isReady: () => false,
      notReadyMessage: () => SHADOW_BRIDGE_MESSAGE,
    });

    const res = await handler('get_selected_photos', {});

    expect(res.isError).toBe(true);
    expect(res.content[0].text).toBe(SHADOW_BRIDGE_MESSAGE);
    expect(dispatcher.call).not.toHaveBeenCalled();
  });

  it('waits for readiness to settle before dispatching a call', async () => {
    const liveness = new PluginLiveness();
    liveness.beginProbe();
    const call = jest.fn(() => Promise.resolve({ id: 'req_1', result: {} }));
    const handler = createCallToolHandler({
      dispatcher: { call },
      isReady: () => liveness.isUsable(),
      notReadyMessage: () => SHADOW_BRIDGE_MESSAGE,
      settleReadiness: () => liveness.settled(),
    });

    const pending = handler('get_selected_photos', {});
    await Promise.resolve();
    expect(call).not.toHaveBeenCalled();

    liveness.markUnresponsive();
    const res = await pending;

    expect(res.isError).toBe(true);
    expect(res.content[0].text).toBe(SHADOW_BRIDGE_MESSAGE);
    expect(call).not.toHaveBeenCalled();
  });

  it('falls back to the not-connected message when no reason is supplied', async () => {
    const handler = createCallToolHandler({ dispatcher, isReady: () => false });

    const res = await handler('get_selected_photos', {});

    expect(res.content[0].text).toContain("click 'Start Server'");
  });
});
