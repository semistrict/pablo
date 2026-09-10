import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../../Resources/background.js', import.meta.url), 'utf8');
const event = { addListener() {} };

test('the native connection remains active and replaces its heartbeat on disconnect', () => {
  const timers = new Map(), ports = [];
  let nextTimer = 0;
  const context = vm.createContext({
    TextEncoder, TextDecoder,
    setTimeout(callback, delay) { timers.set(++nextTimer, { callback, delay }); return nextTimer; },
    clearTimeout(id) { timers.delete(id); },
    browser: {
      action: { onClicked: event }, tabs: { onUpdated: event, onRemoved: event },
      runtime: { onMessage: event, connectNative() {
        const port = { sent: [], onMessage: event,
          onDisconnect: { addListener(callback) { port.disconnect = callback; } },
          postMessage(message) { port.sent.push(message); } };
        ports.push(port);
        return port;
      } },
    },
  });
  vm.runInContext(source, context);
  assert.equal(ports.length, 1);
  assert.equal(ports[0].sent[0]?.kind, 'bridge-ping');
  let [id, timer] = [...timers.entries()][0];
  assert.ok(timer.delay > 1000 && timer.delay < 30000);
  timers.delete(id); timer.callback();
  assert.equal(ports[0].sent.length, 2);
  ports[0].disconnect();
  assert.equal(timers.size, 1);
  [id, timer] = [...timers.entries()][0];
  assert.equal(timer.delay, 1000);
  timers.delete(id); timer.callback();
  assert.equal(ports.length, 2);
  assert.equal(ports[1].sent[0]?.kind, 'bridge-ping');
  assert.equal(timers.size, 1);
});
