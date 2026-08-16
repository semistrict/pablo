import { record } from "@rrweb/record";

const STATE_KEY = "__pabloRRWebRecorderState";
const MESSAGE = "pablo-rrweb";

if (!globalThis[STATE_KEY]) {
  globalThis[STATE_KEY] = {
    recordingID: null,
    status: "idle",
    stop: null,
    events: [],
    sequence: 0,
    eventCount: 0,
    flushTimer: null,
    pendingFlush: Promise.resolve(),
    deliveryError: null,
  };
  browser.runtime.onMessage.addListener((message) => {
    if (message?.type !== MESSAGE) return undefined;
    return handleCommand(message);
  });
}

const state = globalThis[STATE_KEY];

function scheduleFlush() {
  if (state.flushTimer) return;
  state.flushTimer = setTimeout(() => {
    state.flushTimer = null;
    void flushEvents();
  }, 500);
}

async function flushEvents() {
  if (!state.events.length || !state.recordingID) return;
  const events = state.events;
  const sequence = state.sequence++;
  const recordingID = state.recordingID;
  state.events = [];
  state.pendingFlush = state.pendingFlush.then(async () => {
    try {
      await browser.runtime.sendMessage({
        type: `${MESSAGE}-events`,
        recordingID,
        sequence,
        events,
      });
    } catch (error) {
      state.deliveryError = String(error?.message || error);
      try {
        await browser.runtime.sendMessage({
          type: `${MESSAGE}-error`,
          recordingID,
          error: `Could not persist rrweb event batch ${sequence}: ${state.deliveryError}`,
        });
      } catch (_) {
        // The failed delivery is still surfaced in status if the native bridge is unavailable.
      }
    }
  });
  await state.pendingFlush;
}

function beginRecorder() {
  state.stop = record({
    emit(event) {
      state.events.push(event);
      state.eventCount += 1;
      if (state.events.length >= 25) void flushEvents();
      else scheduleFlush();
    },
    maskAllInputs: true,
    recordCanvas: false,
    recordCrossOriginIframes: false,
    collectFonts: false,
    checkoutEveryNms: 60_000,
    errorHandler(error) {
      void browser.runtime.sendMessage({
        type: `${MESSAGE}-error`,
        recordingID: state.recordingID,
        error: String(error?.message || error),
      });
    },
  });
  state.status = "recording";
}

async function handleCommand(message) {
  switch (message.command) {
    case "start":
      if (state.status !== "idle") throw new Error("This tab already has an rrweb recording.");
      state.recordingID = message.recordingID;
      state.sequence = 0;
      state.eventCount = 0;
      state.events = [];
      state.deliveryError = null;
      beginRecorder();
      return statusPayload();
    case "pause":
      requireRecording(message.recordingID);
      if (state.status === "recording") {
        state.stop?.();
        state.stop = null;
        state.status = "paused";
        await flushEvents();
      }
      return statusPayload();
    case "resume":
      requireRecording(message.recordingID);
      if (state.status === "paused") beginRecorder();
      return statusPayload();
    case "stop": {
      requireRecording(message.recordingID);
      state.stop?.();
      state.stop = null;
      if (state.flushTimer) clearTimeout(state.flushTimer);
      state.flushTimer = null;
      await flushEvents();
      const result = statusPayload("stopped");
      state.recordingID = null;
      state.status = "idle";
      state.eventCount = 0;
      state.sequence = 0;
      return result;
    }
    case "status":
      return statusPayload();
    default:
      throw new Error(`Unsupported rrweb command ${message.command}.`);
  }
}

function requireRecording(recordingID) {
  if (!state.recordingID || state.recordingID !== recordingID) {
    throw new Error("The requested rrweb recording is not active in this tab.");
  }
}

function statusPayload(status = state.status) {
  return {
    recordingID: state.recordingID,
    status,
    eventCount: state.eventCount,
    nextSequence: state.sequence,
    error: state.deliveryError,
    title: document.title,
    url: location.href,
  };
}
