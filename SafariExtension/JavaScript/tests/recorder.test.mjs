import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { test } from "node:test";
import vm from "node:vm";
import { build } from "esbuild";

const bundled = await build({
  entryPoints: [new URL("../recorder-entry.js", import.meta.url).pathname],
  bundle: true,
  write: false,
  format: "iife",
  plugins: [{
    name: "rrweb-fixture",
    setup(builder) {
      builder.onResolve({ filter: /^@rrweb\/record$/ }, () => ({ path: "record", namespace: "fixture" }));
      builder.onLoad({ filter: /.*/, namespace: "fixture" }, () => ({
        contents: "export const record = options => globalThis.startFixtureRecording(options);",
      }));
    },
  }],
});

function recorderFixture(sendMessage) {
  let listener;
  let emit;
  let starts = 0;
  const timers = new Map();
  let timerID = 0;
  const context = {
    browser: { runtime: {
      onMessage: { addListener(value) { listener = value; } },
      sendMessage,
    } },
    startFixtureRecording(options) { starts++; emit = options.emit; return () => {}; },
    setTimeout(callback) { timers.set(++timerID, callback); return timerID; },
    clearTimeout(id) { timers.delete(id); },
    document: { title: "Fixture" },
    location: { href: "https://example.test/" },
  };
  context.__pabloTabGrant = { document: context.document, token: "fixture-grant" };
  vm.runInNewContext(bundled.outputFiles[0].text, context);
  return {
    starts() { return starts; },
    command(command, accessToken = "fixture-grant") { return listener({ type: "pablo-rrweb", command, recordingID: "fixture-recording", accessToken }); },
    emit(event) { emit(event); },
    flushTimer() {
      for (const [id, callback] of timers) { timers.delete(id); callback(); }
    },
  };
}

for (const command of ["pause", "stop"]) {
  test(`${command} waits for an already-sending batch even when its buffer is empty`, async () => {
    let deliver;
    const delivery = new Promise(resolve => { deliver = resolve; });
    const batches = [];
    const fixture = recorderFixture(async message => {
      batches.push(message);
      await delivery;
    });
    await fixture.command("start");
    fixture.emit({ type: 2, timestamp: 1000, data: {} });
    fixture.flushTimer();
    await setImmediate();
    assert.equal(batches.length, 1);
    let acknowledged = false;
    const completion = fixture.command(command).then(value => { acknowledged = true; return value; });
    try {
      await setImmediate();
      assert.equal(acknowledged, false, "Finalization must wait for durable delivery.");
    } finally {
      deliver();
      await completion;
    }
    const result = await completion;
    assert.equal(result.eventCount, 1);
    assert.equal(result.nextSequence, 1);
    assert.equal(batches.length, 1);
    assert.equal(result.error, null);
  });
}

test("failed event delivery is included in the stop acknowledgment", async () => {
  const fixture = recorderFixture(async message => {
    if (message.type === "pablo-rrweb-events") throw new Error("fixture storage unavailable");
  });
  await fixture.command("start");
  fixture.emit({ type: 2, timestamp: 1000, data: {} });
  const stopped = await fixture.command("stop");
  assert.match(stopped.error, /fixture storage unavailable/);
});

test('stopped recording receipts can be read and replayed without restarting capture', async () => {
  const fixture = recorderFixture(async () => {});
  await fixture.command('start');
  fixture.emit({ type: 2, timestamp: 1000, data: {} });
  const stopped = await fixture.command('stop');
  const status = await fixture.command('status');
  assert.equal(status.recordingID, stopped.recordingID);
  assert.equal(status.status, 'stopped');
  const retried = await fixture.command('stop');
  assert.deepEqual(retried, stopped);
});

test('recording transitions serialize while a pause awaits durable delivery', async () => {
  let deliver;
  const delivery = new Promise(resolve => { deliver = resolve; });
  const fixture = recorderFixture(async () => { await delivery; });
  await fixture.command('start');
  fixture.emit({ type: 2, timestamp: 1000, data: {} });
  const pause = fixture.command('pause');
  const resume = fixture.command('resume');
  try {
    await setImmediate();
    assert.equal(fixture.starts(), 1);
  } finally { deliver(); await Promise.allSettled([pause, resume]); }
  assert.equal((await pause).status, 'paused');
  assert.equal((await resume).status, 'recording');
  assert.equal(fixture.starts(), 2);
});

test('recording cannot start with an expired document grant', async () => {
  const fixture = recorderFixture(async () => {});
  await assert.rejects(fixture.command('start', 'expired-grant'), /document is locked/);
  assert.equal(fixture.starts(), 0);
});
