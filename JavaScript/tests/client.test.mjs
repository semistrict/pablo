import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { Pablo, PabloError } from '../src/index.mjs';

const serviceID = '11111111-1111-4111-8111-111111111111';
const sessionID = '22222222-2222-4222-8222-222222222222';
const documentGeneration = '33333333-3333-4333-8333-333333333333';
const frame = index => `LIVE-${sessionID}/A11Y-${String(index).padStart(3, '0')}`;
const node = (id, title = id, role = 'AXButton') => ({ id, title, role, childIDs: [], depth: 0 });
const response = output => ({ id: randomUUID(), result: { state: 'idle', output } });
const receipt = (request, output) => ({ serviceID, operationID: request.operationID, method: request.method,
  status: 'completed', resultOmitted: false, expiresAt: new Date(Date.now() + 300_000).toISOString(), response: response(output) });
function observation(index, { baseline, nodes = [node('field', 'Editor', 'AXTextField')], changes = [], resyncRequired = false, windowID } = {}) {
  return { id: randomUUID(), target: { pid: 42, applicationName: 'Fixture', ...(windowID ? { windowID } : {}) },
    tree: { sessionID, reference: frame(index), mode: baseline ? 'delta' : 'full', baselineReference: baseline,
      resyncRequired, rootID: nodes[0]?.id ?? 'field', timestampNs: index, totalNodeCount: nodes.length,
      truncated: false, nodes: baseline ? [] : nodes, changes, text: baseline ? '~ field' : '= field', textTruncated: false },
    settleStatus: 'settled', sampleCount: 4, elapsedMilliseconds: 150 };
}

async function fixture(t, handler) {
  const directory = await mkdtemp(join(tmpdir(), 'pablo-client-'));
  const socketPath = join(directory, 'control.sock');
  const calls = [];
  const server = http.createServer(async (request, reply) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    const payload = JSON.parse(body);
    calls.push({ method: request.url.slice(1), payload });
    if (request.url === '/service.info') {
      reply.writeHead(200, { 'Content-Type': 'application/json' });
      reply.end(JSON.stringify(response({ serviceID })));
      return;
    }
    try {
      const result = await handler(request.url.slice(1), payload, reply);
      if (result === undefined) return;
      reply.writeHead(200, { 'Content-Type': 'application/json' });
      reply.end(JSON.stringify(result));
    } catch (error) {
      reply.writeHead(500); reply.end(JSON.stringify({ error: error.message }));
    }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
  t.after(async () => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  });
  return { client: await Pablo.connect({ socketPath }), calls };
}

test('app handles materialize compact diffs and pin observed context on each action', async t => {
  let reads = 0;
  let actions = 0;
  const { client, calls } = await fixture(t, (method, payload) => {
    if (method === 'inspect.live') {
      reads += 1;
      return response(observation(reads));
    }
    assert.equal(method, 'operation.execute');
    actions += 1;
    const request = payload.payload;
    assert.equal(request.target.pid, 42);
    assert.equal(request.target.sessionID, sessionID);
    assert.equal(request.target.frameReference, frame(actions));
    assert.equal(request.observation.baselineReference, frame(actions));
    assert.equal(request.unlockForegroundActions, false);
    return response(receipt(payload, { actionID: payload.operationID, dispatchStatus: 'dispatched', effectStatus: 'unverified',
      observation: observation(actions + 1, { baseline: frame(actions), changes: [
        { kind: 'updated', nodeID: 'field', node: node('field', `Value ${actions}`, 'AXTextField'), changedProperties: ['title'] }
      ] }) }));
  });
  const app = await client.app('Fixture');
  const result = await app.setValue('field', 'First');
  assert.equal(result.effectStatus, 'unverified');
  assert.equal(app.nodes[0].title, 'Value 1');
  result.observation.tree.changes[0].node.title = 'Caller mutation';
  assert.equal(app.nodes[0].title, 'Value 1');
  await app.selectText('field', 'Value', { selectionType: 'cursorAfter' });
  assert.equal(app.state.tree.reference, frame(3));
  assert.equal(reads, 1, 'actions include observations without extra inspection requests');
  assert.equal(calls.filter(call => call.method === 'operation.execute').length, 2);
});

test('full resynchronization replaces cached nodes and sampling budgets reach the native app', async t => {
  let reads = 0;
  const { client, calls } = await fixture(t, (method, payload) => {
    assert.equal(method, 'inspect.live');
    reads += 1;
    if (reads === 1) return response(observation(1));
    assert.equal(payload.observation.baselineReference, frame(1));
    assert.equal(payload.observation.timeoutMilliseconds, 250);
    return response(observation(2, { nodes: [node('replacement')], resyncRequired: true }));
  });
  const app = await client.app({ bundleIdentifier: 'example.fixture' });
  await app.getState({ timeoutMilliseconds: 250 });
  assert.deepEqual(app.nodes.map(node => node.id), ['replacement']);
  await assert.rejects(app.click('field'), /absent/);
  assert.equal(calls.filter(call => call.method === 'operation.execute').length, 0);
});

test('a mismatched post-action baseline preserves dispatch and invalidates cached state', async t => {
  const { client } = await fixture(t, (method, payload) => {
    if (method === 'inspect.live') return response(observation(1));
    return response(receipt(payload, { actionID: payload.operationID, dispatchStatus: 'dispatched', effectStatus: 'unverified',
      observation: observation(2, { baseline: frame(99) }) }));
  });
  const app = await client.app('Fixture');
  const result = await app.click('field');
  assert.equal(result.dispatchStatus, 'dispatched');
  assert.equal(result.observationFailure.code, 'invalidObservation');
  assert.equal(app.state, undefined);
  assert.deepEqual(app.nodes, []);
});

test('a lost execute response is recovered by receipt lookup without redispatch', async t => {
  let completed;
  let effects = 0;
  const { client, calls } = await fixture(t, (method, payload, reply) => {
    if (method === 'operation.execute') {
      effects += 1;
      completed = receipt(payload, { actionID: payload.operationID, dispatchStatus: 'dispatched', effectStatus: 'unverified' });
      reply.destroy();
      return;
    }
    assert.equal(method, 'operation.status');
    assert.equal(payload.operationID, completed.operationID);
    return response(completed);
  });
  const result = await client.mutate('action.live', { kind: 'key', target: { pid: 42 }, key: 'return' });
  assert.equal(result.dispatchStatus, 'dispatched');
  assert.equal(effects, 1);
  assert.deepEqual(calls.slice(1).map(call => call.method), ['operation.execute', 'operation.status']);
});

test('an unavailable receipt exposes uncertainty and never repeats the action', async t => {
  let effects = 0;
  const { client, calls } = await fixture(t, (method, payload, reply) => {
    if (method === 'operation.execute') { effects += 1; reply.destroy(); return; }
    return { error: 'Receipt expired', failure: { code: 'invalidRequest', dispatchStatus: 'notDispatched' } };
  });
  await assert.rejects(client.mutate('action.live', { kind: 'click' }), error => {
    assert.ok(error instanceof PabloError);
    assert.equal(error.operation.serviceID, serviceID);
    assert.match(error.message, /do not replay/);
    return true;
  });
  assert.equal(effects, 1);
  assert.equal(calls.filter(call => call.method === 'operation.execute').length, 1);
});

test('abort requests cancellation of the same operation instead of replaying it', async t => {
  const abort = new AbortController();
  let operation;
  const { client, calls } = await fixture(t, (method, payload) => {
    if (method === 'operation.execute') { operation = payload; abort.abort(); return; }
    assert.equal(method, 'operation.cancel');
    assert.equal(payload.operationID, operation.operationID);
    return response({ ...receipt(operation, null), status: 'rejected', response: {
      error: 'Cancelled before dispatch', failure: { code: 'cancelled', dispatchStatus: 'notDispatched' }
    } });
  });
  await assert.rejects(client.mutate('action.live', { kind: 'click' }, { signal: abort.signal }), error => {
    assert.equal(error.failure.code, 'cancelled');
    assert.equal(error.operation.operationID, operation.operationID);
    return true;
  });
  assert.deepEqual(calls.slice(1).map(call => call.method), ['operation.execute', 'operation.cancel']);
});

test('request size limits and read-only routing reject invalid work before dispatch', async t => {
  const { client, calls } = await fixture(t, () => { throw new Error('No action expected'); });
  await assert.rejects(client.read('action.live', { kind: 'click' }), /mutate/);
  await assert.rejects(client.mutate('action.live', { text: 'x'.repeat(64 * 1024) }), /64 KiB/);
  assert.equal(calls.length, 1);
});

test('Safari handles preserve document generations and keep action results when follow-up observation fails', async t => {
  let reads = 0;
  const { client, calls } = await fixture(t, (method, payload) => {
    if (method === 'safari.dom') {
      reads += 1;
      if (reads === 1) return response({ documentGeneration, root: { nodeID: 'dom-field', role: 'textbox' } });
      assert.equal(payload.documentGeneration, documentGeneration);
      return { error: 'Document navigated', failure: { code: 'permissionRequired', dispatchStatus: 'notDispatched' } };
    }
    assert.equal(payload.payload.documentGeneration, documentGeneration);
    assert.equal(payload.payload.tabID, 23);
    return response(receipt(payload, { actionID: payload.operationID, dispatchStatus: 'dispatched', effectStatus: 'unverified' }));
  });
  const tab = await client.tab(23);
  const result = await tab.click('dom-field');
  assert.equal(result.dispatchStatus, 'dispatched');
  assert.equal(result.observationFailure.code, 'permissionRequired');
  assert.equal(tab.state, undefined);
  assert.equal(calls.filter(call => call.method === 'operation.execute').length, 1);
});
