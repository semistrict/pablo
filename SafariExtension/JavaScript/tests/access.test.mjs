import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';
import { randomUUID } from 'node:crypto';

const source = await readFile(new URL('../../Resources/background.js', import.meta.url), 'utf8');
const event = { addListener() {} };

function fixture(allowed, actionFails = false, domPayload = { dispatchStatus: 'dispatched' }) {
  const scripts = [];
  let onClicked, onUpdated, onRemoved;
  let page = vm.createContext({ document: { title: 'Fixture' }, location: { href: 'https://example.test/' } });
  const context = vm.createContext({
    TextEncoder, TextDecoder, atob, btoa, setTimeout: () => 1, clearTimeout() {}, crypto: { randomUUID },
    browser: {
      action: { onClicked: { addListener(value) { onClicked = value; } },
        async setBadgeBackgroundColor() {}, async setBadgeText() {}, async setTitle() {} },
      tabs: { onUpdated: { addListener(value) { onUpdated = value; } },
        onRemoved: { addListener(value) { onRemoved = value; } }, get: async id => ({ id }), query: async () => [{ id: 42 }] },
      runtime: { onMessage: event, connectNative: () => ({ onMessage: event, onDisconnect: event, postMessage() {} }) },
      scripting: { executeScript: async options => {
        scripts.push(options.func?.name === 'executeDOMCommand' ? 'executeDOMCommand' : 'probe');
        if (!allowed) throw new Error('Invalid call to scripting.executeScript(). This extension does not have access to this tab.');
        if (actionFails && options.func?.name === 'executeDOMCommand') throw new Error('Reply interrupted after submission');
        return [{ result: options.func?.name === 'executeDOMCommand' ? { success: true, payload: domPayload } :
          vm.runInContext(`(${options.func.toString()})(...${JSON.stringify(options.args || [])})`, page) }];
      } },
    },
  });
  vm.runInContext(source, context);
  return {
    scripts,
    async unlock() { await onClicked({ id: 42 }); scripts.length = 0; },
    navigate(notify = true) {
      page = vm.createContext({ document: { title: 'Next page' }, location: { href: 'https://example.test/next' } });
      if (notify) onUpdated(42, { status: 'loading', url: 'https://example.test/next' });
    },
    close() { onRemoved(42); },
    async run(kind) {
      context.kind = kind;
      const response = await vm.runInContext(`(() => {
        const bytes = []; writeString(bytes, 1, 'fixture'); writeVarintField(bytes, 2, kind); writeVarintField(bytes, 9, 42);
        return handleSerializedCommand(toBase64(new Uint8Array(bytes)));
      })()`, context);
      context.response = response;
      return vm.runInContext(`(() => {
        const reader = protobufReader(fromBase64(response.response)); const value = {};
        while (!reader.done()) {
          const tag = reader.varint(), field = tag >>> 3, wire = tag & 7;
          if (field === 1) value.id = reader.string();
          else if (field === 2) value.success = reader.varint() === 1;
          else if (field === 3) value.payload = JSON.parse(reader.string());
          else if (field === 4) value.error = reader.string();
          else reader.skip(wire);
        }
        return value;
      })()`, context);
    },
  };
}

test('a locked tab reports its human prerequisite before dispatching a DOM read or mutation', async () => {
  for (const kind of [2, 3]) {
    const bridge = fixture(false);
    const result = await bridge.run(kind);
    assert.equal(result.success, false);
    assert.equal(result.payload?.errorCode, 'permissionRequired');
    assert.equal(result.payload?.dispatchStatus, 'notDispatched');
    assert.match(result.error, /Unlock this tab for Pablo/);
    assert.ok(!bridge.scripts.includes('executeDOMCommand'));
  }
});

test('an accessible tab reaches the requested DOM action after the access probe', async () => {
  const bridge = fixture(true);
  await bridge.unlock();
  const result = await bridge.run(3);
  assert.equal(result.success, true);
  assert.deepEqual(bridge.scripts, ['probe', 'executeDOMCommand']);
});

test('a near-limit DOM response survives native protobuf and base64 transport intact', async () => {
  const payload = { kind: 'accessibility', truncated: true, byteBudgetReached: true,
    root: { role: 'text', text: '界🌈'.repeat(145000) } };
  assert.ok(Buffer.byteLength(JSON.stringify(payload)) < 1024 * 1024);
  const bridge = fixture(true, false, payload);
  await bridge.unlock();
  const result = await bridge.run(2);
  assert.equal(result.success, true, result.error);
  assert.equal(JSON.stringify(result.payload), JSON.stringify(payload));
});


test('a failure after action submission never advertises no dispatch', async () => {
  const bridge = fixture(true, true);
  await bridge.unlock();
  const result = await bridge.run(3);
  assert.equal(result.success, false);
  assert.notEqual(result.payload?.dispatchStatus, 'notDispatched');
  assert.notEqual(result.payload?.errorCode, 'permissionRequired');
});

for (const lifecycle of ['not unlocked', 'navigation', 'navigation before event', 'close']) {
  test(`Safari-retained access does not authorize a tab after ${lifecycle}`, async () => {
    const bridge = fixture(true);
    if (lifecycle !== 'not unlocked') await bridge.unlock();
    if (lifecycle.startsWith('navigation')) bridge.navigate(lifecycle !== 'navigation before event');
    if (lifecycle === 'close') bridge.close();
    const tabs = await bridge.run(7);
    assert.equal(tabs.success, true);
    assert.equal(tabs.payload.tabs.length, 0);
    for (const kind of [2, 3, 8]) {
      const result = await bridge.run(kind);
      assert.equal(result.success, false);
      assert.equal(result.payload?.errorCode, 'permissionRequired');
      assert.equal(result.payload?.dispatchStatus, 'notDispatched');
    }
    assert.ok(!bridge.scripts.includes('executeDOMCommand'));
  });
}
