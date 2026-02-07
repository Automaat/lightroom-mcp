// Test MCP tool call
import fetch from 'node-fetch';

const MCP_SERVER = 'http://localhost:8765';

async function testListCollections() {
  console.log('Queuing list_collections request...');

  // Simulate MCP queuing a request
  const requestId = `req_${Date.now()}_test`;

  // Queue the request (simulate what MCP server does)
  const response = await fetch(`${MCP_SERVER}/poll-request`);
  const currentQueue = await response.json();
  console.log('Current queue:', currentQueue);

  // Now actually test by directly adding to server's internal queue
  // We need to trigger a tool call through the MCP server

  console.log('\nTo test properly, we need to call the MCP server via stdio');
  console.log('But we can verify the endpoints:');

  const health = await fetch(`${MCP_SERVER}/health`);
  const healthData = await health.json();
  console.log('Health:', healthData);
}

testListCollections().catch(console.error);
