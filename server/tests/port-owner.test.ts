import net from 'node:net';
import { describe, it, expect, jest } from '@jest/globals';
import {
  describeUnresponsive,
  diagnoseUnresponsive,
  findPortClients,
  findPortListener,
  parseLsofClients,
  parseLsofListeners,
  parseNetstatClients,
  parseNetstatListeners,
  parseTasklist,
  runCommand,
  type PortListener,
  type PortOwnership,
  type RunCommand,
  STALE_LISTENER_MESSAGE,
  UnresponsiveReporter,
} from '../src/port-owner.js';
import { SHADOW_BRIDGE_MESSAGE } from '../src/plugin-liveness.js';

const LIGHTROOM: PortListener = { pid: 27120, command: 'Adobe Lightroom Classic' };
const FOREIGN: PortListener = { pid: 4242, command: 'python3.13' };
const MIDI2LR_APP: PortListener = { pid: 555, command: 'MIDI2LR' };

const NETSTAT = [
  'Active Connections',
  '',
  '  Proto  Local Address          Foreign Address        State           PID',
  '  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1100',
  '  TCP    127.0.0.1:58763        0.0.0.0:0              LISTENING       5000',
  '  TCP    127.0.0.1:58764        0.0.0.0:0              LISTENING       4242',
  '  TCP    127.0.0.1:58764        127.0.0.1:61234        ESTABLISHED     4242',
  '  TCP    127.0.0.1:61234        127.0.0.1:58764        ESTABLISHED     7777',
  '  TCP    127.0.0.1:61299        127.0.0.1:58764        TIME_WAIT       0',
  '  TCP    127.0.0.1:158764       0.0.0.0:0              LISTENING       9999',
  '  TCP    [::]:58763             [::]:0                 LISTENING       5001',
].join('\r\n');

const NETSTAT_GERMAN = [
  '  Proto  Lokale Adresse         Remoteadresse          Status           PID',
  '  TCP    127.0.0.1:58764        0.0.0.0:0              ABHÖREN          4242',
  '  TCP    127.0.0.1:61234        127.0.0.1:58764        HERGESTELLT      7777',
].join('\r\n');

const TASKLIST = [
  '"System Idle Process","0","Services","0","8 K"',
  '"Lightroom.exe","5000","Console","1","900,000 K"',
  '"MIDI2LR.exe","7777","Console","1","52,000 K"',
].join('\r\n');

const LSOF_ESTABLISHED = [
  'p27120', 'cAdobe Lightroom Classic',
  'f68', 'n127.0.0.1:58764->127.0.0.1:61146',
  'p555', 'cMIDI2LR',
  'f23', 'n127.0.0.1:61146->127.0.0.1:58764',
  'p777', 'cnode',
  'f24', 'n127.0.0.1:61200->127.0.0.1:58764',
  'f25', 'n127.0.0.1:61201->127.0.0.1:58763',
].join('\n');

function fakeRun(outputs: Record<string, string>): RunCommand {
  return (file) => {
    if (!(file in outputs)) return Promise.reject(new Error(`${file}: not found`));
    return Promise.resolve(outputs[file]);
  };
}

describe('parseLsofListeners', () => {
  it.each([
    ['one listener', 'p27120\ncAdobe Lightroom Classic\nf65\n', [LIGHTROOM]],
    ['no command field', 'p27120\nf65\n', [{ pid: 27120 }]],
    ['nothing listening', '', []],
    ['two listeners', 'p1\ncfoo\np2\ncbar\n', [{ pid: 1, command: 'foo' }, { pid: 2, command: 'bar' }]],
    ['garbage pid, orphan command', 'pabc\ncfoo\n', []],
  ])('%s', (_name, output, expected) => {
    expect(parseLsofListeners(output)).toEqual(expected);
  });
});

describe('parseNetstatListeners', () => {
  it.each([
    ['IPv4 and IPv6 listeners', NETSTAT, 58763, [5000, 5001]],
    ['a listener, not its accepted connection', NETSTAT, 58764, [4242]],
    ['no listener', NETSTAT, 12345, []],
    ['localized state column', NETSTAT_GERMAN, 58764, [4242]],
  ])('%s', (_name, output, port, expected) => {
    expect(parseNetstatListeners(output, port)).toEqual(expected);
  });
});

describe('parseLsofClients', () => {
  it('keeps only the connecting end, never the listener side', () => {
    expect(parseLsofClients(LSOF_ESTABLISHED, 58764).map((c) => c.pid)).toEqual([555, 777]);
  });

  it('matches the requested port only', () => {
    expect(parseLsofClients(LSOF_ESTABLISHED, 58763).map((c) => c.pid)).toEqual([777]);
  });

  it('ignores connections of a garbage pid record', () => {
    expect(parseLsofClients('pabc\ncnode\nn127.0.0.1:1->127.0.0.1:58764\n', 58764)).toEqual([]);
  });
});

describe('parseNetstatClients', () => {
  it.each([
    ['the outbound end, skipping pid 0 TIME_WAIT rows', NETSTAT, 58764, [7777]],
    ['no connections to that port', NETSTAT, 58763, []],
    ['localized state column', NETSTAT_GERMAN, 58764, [7777]],
  ])('%s', (_name, output, port, expected) => {
    expect(parseNetstatClients(output, port)).toEqual(expected);
  });
});

describe('parseTasklist', () => {
  it('maps pids to image names', () => {
    const names = parseTasklist(TASKLIST);

    expect(names.get(5000)).toBe('Lightroom.exe');
    expect(names.get(7777)).toBe('MIDI2LR.exe');
  });

  it('ignores the no-match notice', () => {
    expect(parseTasklist('INFO: No tasks are running which match the specified criteria.').size).toBe(0);
  });
});

describe('findPortListener', () => {
  it('resolves the listener via lsof on macOS', async () => {
    const run = fakeRun({ lsof: 'p27120\ncAdobe Lightroom Classic\nf65\n' });

    await expect(findPortListener(58764, 'darwin', run)).resolves.toEqual(LIGHTROOM);
  });

  it('resolves pid and image name via netstat and tasklist on Windows', async () => {
    const run = fakeRun({ netstat: NETSTAT, tasklist: TASKLIST });

    await expect(findPortListener(58763, 'win32', run)).resolves.toEqual({ pid: 5000, command: 'Lightroom.exe' });
  });

  it('still reports the pid when tasklist is unavailable', async () => {
    const run = fakeRun({ netstat: NETSTAT });

    await expect(findPortListener(58764, 'win32', run)).resolves.toEqual({ pid: 4242, command: undefined });
  });

  it.each([
    ['nothing listens', 'darwin' as const, { lsof: '' }],
    ['lsof is missing', 'darwin' as const, {}],
    ['netstat has no match', 'win32' as const, { netstat: '' }],
  ])('returns null when %s', async (_name, platform, outputs) => {
    await expect(findPortListener(58764, platform, fakeRun(outputs))).resolves.toBeNull();
  });
});

describe('findPortClients', () => {
  it('excludes this bridge itself', async () => {
    const run = fakeRun({ lsof: LSOF_ESTABLISHED });

    await expect(findPortClients(58764, 777, 'darwin', run)).resolves.toEqual([MIDI2LR_APP]);
  });

  it('names clients via tasklist on Windows', async () => {
    const run = fakeRun({ netstat: NETSTAT, tasklist: TASKLIST });

    await expect(findPortClients(58764, 1, 'win32', run)).resolves.toEqual([{ pid: 7777, command: 'MIDI2LR.exe' }]);
  });

  it('skips tasklist when nobody is connected', async () => {
    const run = fakeRun({ netstat: NETSTAT });

    await expect(findPortClients(58763, 1, 'win32', run)).resolves.toEqual([]);
  });

  it('returns null when it cannot check', async () => {
    await expect(findPortClients(58764, 555, 'darwin', fakeRun({}))).resolves.toBeNull();
  });
});

function owned(listener: PortListener | null, otherClients: PortListener[] | null): PortOwnership[] {
  return [58763, 58764].map((port) => ({ port, listener, otherClients }));
}

describe('describeUnresponsive', () => {
  it.each([
    ['owners are unknown', owned(null, null), SHADOW_BRIDGE_MESSAGE],
    ['clients cannot be listed', owned(LIGHTROOM, null), SHADOW_BRIDGE_MESSAGE],
    ['Lightroom owns the ports and nobody else is connected', owned(LIGHTROOM, []), STALE_LISTENER_MESSAGE],
  ])('%s', (_name, ports, expected) => {
    expect(describeUnresponsive(ports)).toBe(expected);
  });

  it('points at a same-port plugin such as MIDI2LR when Lightroom owns the ports', () => {
    expect(STALE_LISTENER_MESSAGE).toContain('MIDI2LR');
    expect(STALE_LISTENER_MESSAGE).toContain('LIGHTROOM_MCP_REQUEST_PORT');
  });

  it('names connected processes, deduplicated across ports, with both remedies', () => {
    const message = describeUnresponsive(owned(LIGHTROOM, [MIDI2LR_APP]));

    expect(message.match(/MIDI2LR \(pid 555\)/g)).toHaveLength(1);
    expect(message).toContain('pgrep -fl lightroom-mcp');
    expect(message).toContain('LIGHTROOM_MCP_RESPONSE_PORT');
  });

  it('names the foreign process holding a plugin port', () => {
    const message = describeUnresponsive([
      { port: 58763, listener: LIGHTROOM, otherClients: [] },
      { port: 58764, listener: FOREIGN, otherClients: [] },
    ]);

    expect(message).toContain('port 58764 is held by python3.13 (pid 4242)');
    expect(message).not.toContain('58763 is held');
    expect(message).toContain('LIGHTROOM_MCP_RESPONSE_PORT');
  });

  it('still reports a foreign listener whose name is unknown', () => {
    const message = describeUnresponsive([{ port: 58764, listener: { pid: 9 }, otherClients: [] }]);

    expect(message).toContain('port 58764 is held by an unknown process (pid 9)');
  });
});

describe('diagnoseUnresponsive', () => {
  it('checks every port', async () => {
    const owners: Record<number, PortListener | null> = { 58763: LIGHTROOM, 58764: FOREIGN };

    const message = await diagnoseUnresponsive([58763, 58764], {
      listener: (port) => Promise.resolve(owners[port]),
      otherClients: () => Promise.resolve([]),
    });

    expect(message).toContain('port 58764 is held by python3.13');
  });
});

describe('UnresponsiveReporter', () => {
  function setup() {
    let clock = 0;
    const diagnose = jest.fn(() => Promise.resolve(`verdict ${diagnose.mock.calls.length}`));
    const log = jest.fn<(msg: string) => void>();
    const reporter = new UnresponsiveReporter({ diagnose, log, refreshMs: 1000, now: () => clock });
    return { reporter, diagnose, log, advance: (ms: number) => { clock += ms; } };
  }

  it('starts with the generic message', () => {
    expect(setup().reporter.current()).toBe(SHADOW_BRIDGE_MESSAGE);
  });

  it('exposes the verdict once settled, so the first failing tool call already carries it', async () => {
    const { reporter } = setup();

    reporter.report();
    await reporter.settled();

    expect(reporter.current()).toBe('verdict 1');
  });

  it('runs one diagnosis at a time', async () => {
    const { reporter, diagnose } = setup();

    reporter.report();
    reporter.report();
    await reporter.settled();

    expect(diagnose).toHaveBeenCalledTimes(1);
  });

  it('reuses the verdict within the refresh window but still logs it', async () => {
    const { reporter, diagnose, log, advance } = setup();
    reporter.report();
    await reporter.settled();

    advance(999);
    reporter.report();

    expect(diagnose).toHaveBeenCalledTimes(1);
    expect(log).toHaveBeenLastCalledWith('verdict 1');
  });

  it('re-diagnoses after the refresh window', async () => {
    const { reporter, diagnose, advance } = setup();
    reporter.report();
    await reporter.settled();

    advance(1000);
    reporter.report();
    await reporter.settled();

    expect(diagnose).toHaveBeenCalledTimes(2);
    expect(reporter.current()).toBe('verdict 2');
  });

  it('forgets the verdict on recovery, so the next outage is diagnosed fresh', async () => {
    const { reporter, diagnose } = setup();
    reporter.report();
    await reporter.settled();

    reporter.clear();
    expect(reporter.current()).toBe(SHADOW_BRIDGE_MESSAGE);
    reporter.report();
    await reporter.settled();

    expect(diagnose).toHaveBeenCalledTimes(2);
  });
});

describe('runCommand', () => {
  const node = process.execPath;

  it.each([
    ['a clean exit', 'process.stdout.write("hi")'],
    ['a non-zero exit that still printed an answer', 'process.stdout.write("hi"); process.exit(1)'],
  ])('resolves stdout on %s', async (_name, script) => {
    await expect(runCommand(node, ['-e', script])).resolves.toBe('hi');
  });

  it('rejects a failure with no output', async () => {
    await expect(runCommand(node, ['-e', 'process.exit(1)'])).rejects.toThrow();
  });
});

describe('system inspection', () => {
  function listen(): Promise<{ server: net.Server; port: number }> {
    return new Promise((resolve) => {
      const server = net.createServer();
      server.listen(0, '127.0.0.1', () => {
        resolve({ server, port: (server.address() as net.AddressInfo).port });
      });
    });
  }

  it('finds this process as the listener, or reports unknown where the tool is missing', async () => {
    const { server, port } = await listen();
    try {
      const listener = await findPortListener(port);
      const clients = await findPortClients(port);

      expect(listener === null || listener.pid === process.pid).toBe(true);
      expect(clients === null || clients.length === 0).toBe(true);
      await expect(diagnoseUnresponsive([port])).resolves.toEqual(expect.any(String));
    } finally {
      server.close();
    }
  });
});
