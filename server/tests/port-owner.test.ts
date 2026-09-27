import { describe, it, expect } from '@jest/globals';
import {
  describeUnresponsive,
  diagnoseUnresponsive,
  findPortClients,
  findPortListener,
  parseLsofClients,
  parseLsofListeners,
  parseNetstatClients,
  parseNetstatListeners,
  parseTasklistName,
  type PortListener,
  type PortOwnership,
  type RunCommand,
  STALE_LISTENER_MESSAGE,
} from '../src/port-owner.js';
import { SHADOW_BRIDGE_MESSAGE } from '../src/plugin-liveness.js';

const LIGHTROOM: PortListener = { pid: 27120, command: 'Adobe Lightroom Classic' };
const MIDI2LR: PortListener = { pid: 4242, command: 'MIDI2LR' };

const NETSTAT = [
  'Active Connections',
  '',
  '  Proto  Local Address          Foreign Address        State           PID',
  '  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1100',
  '  TCP    127.0.0.1:58763        0.0.0.0:0              LISTENING       5000',
  '  TCP    127.0.0.1:58764        0.0.0.0:0              LISTENING       4242',
  '  TCP    127.0.0.1:61234        127.0.0.1:58764        ESTABLISHED     7777',
  '  TCP    127.0.0.1:158764       0.0.0.0:0              LISTENING       9999',
].join('\r\n');

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
  ])('%s', (_name, output, expected) => {
    expect(parseLsofListeners(output)).toEqual(expected);
  });
});

describe('parseNetstatListeners', () => {
  it.each([
    [58763, [5000]],
    [58764, [4242]],
    [12345, []],
  ])('port %i', (port, expected) => {
    expect(parseNetstatListeners(NETSTAT, port)).toEqual(expected);
  });
});

const LSOF_ESTABLISHED = [
  'p27120', 'cAdobe Lightroom Classic',
  'f68', 'n127.0.0.1:58764->127.0.0.1:61146',
  'p555', 'cnode',
  'f23', 'n127.0.0.1:61146->127.0.0.1:58764',
  'p777', 'cnode',
  'f24', 'n127.0.0.1:61200->127.0.0.1:58764',
  'f25', 'n127.0.0.1:61201->127.0.0.1:58763',
].join('\n');

describe('parseLsofClients', () => {
  it('keeps only the connecting end, never the listener side', () => {
    expect(parseLsofClients(LSOF_ESTABLISHED, 58764).map((c) => c.pid)).toEqual([555, 777]);
  });

  it('matches the requested port only', () => {
    expect(parseLsofClients(LSOF_ESTABLISHED, 58763).map((c) => c.pid)).toEqual([777]);
  });
});

describe('parseNetstatClients', () => {
  it('returns the pid owning the outbound end of a connection to the port', () => {
    expect(parseNetstatClients(NETSTAT, 58764)).toEqual([7777]);
  });
});

describe('findPortClients', () => {
  it('excludes this bridge itself', async () => {
    const run = fakeRun({ lsof: LSOF_ESTABLISHED });

    await expect(findPortClients(58764, 555, 'darwin', run)).resolves.toEqual([777]);
  });

  it('returns null when it cannot check', async () => {
    await expect(findPortClients(58764, 555, 'darwin', fakeRun({}))).resolves.toBeNull();
  });
});

describe('parseTasklistName', () => {
  it.each([
    ['"MIDI2LR.exe","4242","Console","1","52,000 K"', 'MIDI2LR.exe'],
    ['INFO: No tasks are running which match the specified criteria.', undefined],
  ])('%s', (output, expected) => {
    expect(parseTasklistName(output)).toBe(expected);
  });
});

describe('findPortListener', () => {
  it('resolves the listener via lsof on macOS', async () => {
    const run = fakeRun({ lsof: 'p27120\ncAdobe Lightroom Classic\nf65\n' });

    await expect(findPortListener(58764, 'darwin', run)).resolves.toEqual(LIGHTROOM);
  });

  it('resolves pid and image name via netstat and tasklist on Windows', async () => {
    const run = fakeRun({ netstat: NETSTAT, tasklist: '"MIDI2LR.exe","4242","Console","1","52,000 K"' });

    await expect(findPortListener(58764, 'win32', run)).resolves.toEqual({ pid: 4242, command: 'MIDI2LR.exe' });
  });

  it.each([
    ['nothing listens', 'darwin' as const, { lsof: '' }],
    ['lsof is missing', 'darwin' as const, {}],
    ['netstat has no match', 'win32' as const, { netstat: '' }],
  ])('returns null when %s', async (_name, platform, outputs) => {
    await expect(findPortListener(58764, platform, fakeRun(outputs))).resolves.toBeNull();
  });
});

function owned(listener: PortListener | null, otherClients: number[] | null): PortOwnership[] {
  return [58763, 58764].map((port) => ({ port, listener, otherClients }));
}

describe('describeUnresponsive', () => {
  it.each([
    ['Lightroom owns the ports and nobody else is connected', owned(LIGHTROOM, []), STALE_LISTENER_MESSAGE],
    ['owners are unknown', owned(null, null), SHADOW_BRIDGE_MESSAGE],
    ['clients cannot be listed', owned(LIGHTROOM, null), SHADOW_BRIDGE_MESSAGE],
  ])('%s', (_name, ports, expected) => {
    expect(describeUnresponsive(ports)).toBe(expected);
  });

  it('names other connected bridges', () => {
    const message = describeUnresponsive(owned(LIGHTROOM, [555]));

    expect(message).toContain(SHADOW_BRIDGE_MESSAGE);
    expect(message).toContain('pid 555');
  });

  it('names the foreign process holding a plugin port', () => {
    const message = describeUnresponsive([
      { port: 58763, listener: LIGHTROOM, otherClients: [] },
      { port: 58764, listener: MIDI2LR, otherClients: [] },
    ]);

    expect(message).toContain('port 58764 is held by MIDI2LR (pid 4242)');
    expect(message).not.toContain('58763 is held');
    expect(message).toContain('LIGHTROOM_MCP_RESPONSE_PORT');
  });
});

describe('diagnoseUnresponsive', () => {
  it('checks every port', async () => {
    const owners: Record<number, PortListener | null> = { 58763: LIGHTROOM, 58764: MIDI2LR };

    const message = await diagnoseUnresponsive([58763, 58764], {
      listener: (port) => Promise.resolve(owners[port]),
      otherClients: () => Promise.resolve([]),
    });

    expect(message).toContain('port 58764 is held by MIDI2LR');
  });
});
