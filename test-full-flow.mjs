#!/usr/bin/env node

// Test the full flow: queue request → wait for response
const SERVER = 'http://localhost:8765';

async function testFullFlow() {
  console.log('Testing full request/response flow...\n');

  // 1. Queue a request via debug endpoint
  console.log('1. Queuing request...');
  const queueResponse = await fetch(`${SERVER}/debug/queue-request`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'list_collections', params: {} })
  });
  const queueData = await queueResponse.json();
  console.log('   Request queued:', queueData);
  const requestId = queueData.requestId;

  // 2. Wait for plugin to process (similar to MCP handler)
  console.log('\n2. Waiting for plugin to process...');
  const timeoutMs = 30000;
  const startTime = Date.now();
  let responseReceived = false;

  while (Date.now() - startTime < timeoutMs) {
    const healthResponse = await fetch(`${SERVER}/health`);
    const health = await healthResponse.json();

    if (health.pendingResponses > 0) {
      console.log('   ✓ Response received by server!');
      responseReceived = true;
      break;
    }

    // Wait 100ms before checking again
    await new Promise(resolve => setTimeout(resolve, 100));

    const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
    process.stdout.write(`\r   Waiting... ${elapsed}s`);
  }

  if (!responseReceived) {
    console.log('\n   ✗ Timeout: No response received');
    process.exit(1);
  }

  // 3. Check final server state
  console.log('\n\n3. Final server state:');
  const finalHealth = await fetch(`${SERVER}/health`);
  const finalData = await finalHealth.json();
  console.log('   ', finalData);

  console.log('\n✓ Full flow test successful!');
  console.log('  - Request queued');
  console.log('  - Plugin processed request');
  console.log('  - Response submitted to server');
}

testFullFlow().catch(console.error);
