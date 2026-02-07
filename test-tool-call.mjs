#!/usr/bin/env node

// Test MCP tool call via stdio
import { spawn } from 'child_process';

const mcp = spawn('node', ['server/dist/index.js'], {
  stdio: ['pipe', 'pipe', 'inherit']
});

let responseData = '';

mcp.stdout.on('data', (data) => {
  responseData += data.toString();
  console.log('MCP Response:', data.toString());
});

mcp.on('close', (code) => {
  console.log(`MCP process exited with code ${code}`);
  process.exit(code);
});

// Wait for server to start
setTimeout(() => {
  console.log('Sending initialize request...');

  const initRequest = {
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: {
        name: 'test-client',
        version: '1.0.0'
      }
    }
  };

  mcp.stdin.write(JSON.stringify(initRequest) + '\n');

  setTimeout(() => {
    console.log('\nSending list_collections tool call...');

    const toolRequest = {
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/call',
      params: {
        name: 'list_collections',
        arguments: {}
      }
    };

    mcp.stdin.write(JSON.stringify(toolRequest) + '\n');

    // Wait for response then exit
    setTimeout(() => {
      console.log('\nTest complete. Closing connection.');
      mcp.stdin.end();
    }, 10000); // Wait 10 seconds for plugin to process

  }, 1000);

}, 1000);
