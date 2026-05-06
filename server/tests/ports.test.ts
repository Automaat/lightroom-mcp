import { describe, it, expect, beforeEach, afterEach } from '@jest/globals';
import { requestPort, responsePort } from '../src/ports.js';

describe('ports', () => {
  const originalReq = process.env.LIGHTROOM_MCP_REQUEST_PORT;
  const originalRes = process.env.LIGHTROOM_MCP_RESPONSE_PORT;

  beforeEach(() => {
    delete process.env.LIGHTROOM_MCP_REQUEST_PORT;
    delete process.env.LIGHTROOM_MCP_RESPONSE_PORT;
  });

  afterEach(() => {
    if (originalReq === undefined) delete process.env.LIGHTROOM_MCP_REQUEST_PORT;
    else process.env.LIGHTROOM_MCP_REQUEST_PORT = originalReq;
    if (originalRes === undefined) delete process.env.LIGHTROOM_MCP_RESPONSE_PORT;
    else process.env.LIGHTROOM_MCP_RESPONSE_PORT = originalRes;
  });

  it('returns default request port when env unset', () => {
    expect(requestPort()).toBe(58763);
  });

  it('returns default response port when env unset', () => {
    expect(responsePort()).toBe(58764);
  });

  it('treats empty env value as unset', () => {
    process.env.LIGHTROOM_MCP_REQUEST_PORT = '';
    process.env.LIGHTROOM_MCP_RESPONSE_PORT = '   ';
    expect(requestPort()).toBe(58763);
    expect(responsePort()).toBe(58764);
  });

  it('accepts a valid override', () => {
    process.env.LIGHTROOM_MCP_REQUEST_PORT = '12345';
    process.env.LIGHTROOM_MCP_RESPONSE_PORT = '12346';
    expect(requestPort()).toBe(12345);
    expect(responsePort()).toBe(12346);
  });

  it('trims surrounding whitespace', () => {
    process.env.LIGHTROOM_MCP_REQUEST_PORT = '  9000  ';
    expect(requestPort()).toBe(9000);
  });

  it('throws on non-numeric value', () => {
    process.env.LIGHTROOM_MCP_REQUEST_PORT = 'abc';
    expect(() => requestPort()).toThrow(/LIGHTROOM_MCP_REQUEST_PORT/);
    expect(() => requestPort()).toThrow(/abc/);
  });

  it('throws on zero', () => {
    process.env.LIGHTROOM_MCP_RESPONSE_PORT = '0';
    expect(() => responsePort()).toThrow(/LIGHTROOM_MCP_RESPONSE_PORT/);
  });

  it('throws on 65536', () => {
    process.env.LIGHTROOM_MCP_REQUEST_PORT = '65536';
    expect(() => requestPort()).toThrow(/LIGHTROOM_MCP_REQUEST_PORT/);
  });

  it('throws on negative', () => {
    process.env.LIGHTROOM_MCP_REQUEST_PORT = '-1';
    expect(() => requestPort()).toThrow(/LIGHTROOM_MCP_REQUEST_PORT/);
  });

  it('throws on float', () => {
    process.env.LIGHTROOM_MCP_REQUEST_PORT = '1234.5';
    expect(() => requestPort()).toThrow(/LIGHTROOM_MCP_REQUEST_PORT/);
  });

  it('accepts boundary values', () => {
    process.env.LIGHTROOM_MCP_REQUEST_PORT = '1';
    expect(requestPort()).toBe(1);
    process.env.LIGHTROOM_MCP_REQUEST_PORT = '65535';
    expect(requestPort()).toBe(65535);
  });
});
