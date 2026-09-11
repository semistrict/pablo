import http from 'node:http';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

const maximumRequestBytes = 64 * 1024;
const maximumResponseBytes = 16 * 1024 * 1024;
const terminalStatuses = new Set(['completed', 'rejected', 'interrupted', 'outcomeUnknown']);
const readMethods = new Set(['service.info', 'targets.list', 'record.status', 'inspect.live', 'safari.tabs',
  'safari.dom', 'rrweb.status', 'rrweb.recordings', 'rrweb.inspect', 'review.list', 'review.state', 'review.evidence']);
const safariReads = new Set(['dumpDOM', 'dumpAccessibilityTree']);
const mutationMethods = new Set(['action.live', 'safari.dom', 'record.start', 'record.pause', 'record.resume',
  'record.stop', 'annotation.add', 'annotation.resolve', 'rrweb.start', 'rrweb.pause', 'rrweb.resume',
  'rrweb.stop', 'rrweb.recover', 'recording.open']);

export class PabloError extends Error {
  constructor(message, { failure, receipt, operation, cause } = {}) {
    super(message, { cause });
    this.name = 'PabloError';
    this.failure = failure;
    this.receipt = receipt;
    this.operation = operation;
  }
}

function unwrap(response) {
  if (!response || typeof response !== 'object' || !response.result) {
    throw new PabloError(response?.error || 'Pablo returned no result.', { failure: response?.failure });
  }
  return Object.hasOwn(response.result, 'output') ? response.result.output : response.result;
}

function delay(milliseconds, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) { reject(signal.reason ?? new Error('Aborted')); return; }
    const finish = () => { signal?.removeEventListener('abort', abort); resolve(); };
    const timer = setTimeout(finish, milliseconds);
    const abort = () => { clearTimeout(timer); signal?.removeEventListener('abort', abort); reject(signal.reason ?? new Error('Aborted')); };
    signal?.addEventListener('abort', abort, { once: true });
  });
}

/** A persistent client; all privileged decisions remain in the running native app. */
export class Pablo {
  #socketPath;
  #timeoutMilliseconds;
  #service;

  constructor({ socketPath = join(homedir(), 'Library/Application Support/Pablo/control.sock'), timeoutMilliseconds = 30_000 } = {}) {
    if (typeof socketPath !== 'string' || !socketPath || !Number.isInteger(timeoutMilliseconds) || timeoutMilliseconds <= 0) {
      throw new TypeError('A socket path and positive integer timeout are required.');
    }
    this.#socketPath = socketPath;
    this.#timeoutMilliseconds = timeoutMilliseconds;
  }

  static async connect(options) {
    const client = new Pablo(options);
    await client.serviceInfo();
    return client;
  }

  async #request(method, payload = {}, { signal, requestTimeoutMilliseconds = this.#timeoutMilliseconds } = {}) {
    if (!Number.isSafeInteger(requestTimeoutMilliseconds) || requestTimeoutMilliseconds <= 0) throw new RangeError('The transport timeout must be a positive integer.');
    if (signal?.aborted) throw signal.reason ?? new Error('Aborted');
    const body = Buffer.from(JSON.stringify(payload));
    if (body.length > maximumRequestBytes) throw new RangeError('The request exceeds Pablo’s 64 KiB limit.');
    return new Promise((resolve, reject) => {
      const request = http.request({ socketPath: this.#socketPath, path: `/${method}`, method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': body.length, Connection: 'close' }, signal }, response => {
        let length = 0;
        const chunks = [];
        response.on('data', chunk => {
          length += chunk.length;
          if (length > maximumResponseBytes) { request.destroy(new Error('The response exceeds Pablo’s 16 MiB limit.')); return; }
          chunks.push(chunk);
        });
        response.on('error', reject);
        response.on('end', () => {
          try {
            const decoded = JSON.parse(Buffer.concat(chunks).toString('utf8'));
            if (response.statusCode !== 200) {
              reject(new PabloError(decoded.error || `Pablo returned HTTP ${response.statusCode}.`, { failure: decoded.failure }));
            } else { resolve(decoded); }
          } catch (cause) { reject(new PabloError('Pablo returned an invalid JSON response.', { cause })); }
        });
      });
      // A total deadline also bounds a peer that continuously streams small chunks.
      const timer = setTimeout(() => request.destroy(new Error('The Pablo request timed out.')), requestTimeoutMilliseconds);
      request.once('close', () => clearTimeout(timer));
      request.once('error', reject);
      request.end(body);
    });
  }

  async serviceInfo(options) {
    const service = unwrap(await this.#request('service.info', {}, options));
    if (typeof service.serviceID !== 'string') throw new PabloError('Pablo returned no service identity.');
    this.#service = service;
    return service;
  }

  async read(method, payload = {}, options) {
    if (!readMethods.has(method) || (method === 'safari.dom' && !safariReads.has(payload.kind))) {
      throw new TypeError('Use mutate() for supported mutations; read() never dispatches actions.');
    }
    return unwrap(await this.#request(method, payload, options));
  }

  targets(options) { return this.read('targets.list', {}, options); }
  tabs(options) { return this.read('safari.tabs', {}, options); }
  receipt(operation, options) { return this.#request('operation.status', operation, options).then(unwrap); }
  cancel(operation, options) { return this.#request('operation.cancel', operation, options).then(unwrap); }

  async mutate(method, payload, options = {}) {
    if (!mutationMethods.has(method) || (method === 'safari.dom' && safariReads.has(payload.kind))) {
      throw new TypeError('mutate() requires a supported mutation method.');
    }
    if (options.signal?.aborted) throw options.signal.reason ?? new Error('Aborted');
    if (!this.#service) await this.serviceInfo(options);
    const operation = { serviceID: this.#service.serviceID, operationID: randomUUID() };
    const timeout = options.requestTimeoutMilliseconds ?? this.#timeoutMilliseconds;
    if (!Number.isSafeInteger(timeout) || timeout <= 0) throw new RangeError('The transport timeout must be a positive integer.');
    const deadline = Date.now() + timeout;
    const request = { ...operation, issuedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'), method, payload };
    // Validate size before treating any failure as uncertain dispatch.
    if (Buffer.byteLength(JSON.stringify(request)) > maximumRequestBytes) throw new RangeError('The operation exceeds Pablo’s 64 KiB limit.');
    let receipt;
    try {
      receipt = unwrap(await this.#request('operation.execute', request, options));
    } catch (cause) {
      if (cause instanceof PabloError && cause.failure?.dispatchStatus === 'notDispatched') {
        cause.operation = operation;
        throw cause;
      }
      // Never replay a mutation after a transport failure. Only its existing receipt may be queried.
      if (options.signal?.aborted) {
        try { receipt = await this.cancel(operation, { requestTimeoutMilliseconds: 5_000 }); } catch {}
      } else {
        try { receipt = await this.receipt(operation, { requestTimeoutMilliseconds: 5_000 }); } catch {}
      }
      if (!receipt || !terminalStatuses.has(receipt.status)) {
        throw new PabloError('The action outcome is not available. Inspect state or query this operation; do not replay it.',
          { operation, receipt, cause, failure: cause.failure });
      }
    }
    try {
      while (!terminalStatuses.has(receipt.status)) {
        if (Date.now() >= deadline) throw new Error('The operation is still pending.');
        await delay(Math.min(250, deadline - Date.now()), options.signal);
        receipt = await this.receipt(operation, { ...options, requestTimeoutMilliseconds: Math.max(1, deadline - Date.now()) });
      }
    } catch (cause) {
      if (options.signal?.aborted) {
        try { receipt = await this.cancel(operation, { requestTimeoutMilliseconds: 5_000 }); } catch {}
      }
      throw new PabloError('The operation has not produced a final result. Inspect its receipt before taking another action.', { operation, receipt, cause });
    }
    if (receipt.resultOmitted || !receipt.response) {
      throw new PabloError('The retained operation result is unavailable. The action must not be repeated automatically; inspect current state.', { operation, receipt });
    }
    try { return unwrap(receipt.response); }
    catch (error) { error.operation = operation; error.receipt = receipt; throw error; }
  }

  async app(selector, options) {
    const target = typeof selector === 'string' ? { appName: selector } : { ...selector };
    const keys = ['pid', 'bundleIdentifier', 'appName'].filter(key => target[key] !== undefined);
    if (keys.length !== 1) throw new TypeError('Select an app by one name, bundleIdentifier, or pid.');
    const handle = new PabloApp(this, target);
    await handle.getState(options);
    return handle;
  }

  async tab(tabID, options) {
    if (!Number.isSafeInteger(tabID) || tabID <= 0) throw new TypeError('A positive Safari tab ID is required.');
    const handle = new PabloTab(this, tabID);
    await handle.getState(options);
    return handle;
  }
}

class SerialHandle {
  #tail = Promise.resolve();
  enqueue(action) {
    const result = this.#tail.then(action);
    this.#tail = result.catch(() => {});
    return result;
  }
}

function actionLocation(target, nodeKey = 'nodeID', pointKey = 'point') {
  if (typeof target === 'string') return { [nodeKey]: target };
  if (target && Number.isFinite(target.x) && Number.isFinite(target.y)) return { [pointKey]: { x: target.x, y: target.y } };
  throw new TypeError('Use an observed node ID or a normalized {x, y} point.');
}

export class PabloApp extends SerialHandle {
  #client;
  #target;
  #state;
  #nodes = new Map();
  constructor(client, target) { super(); this.#client = client; this.#target = { ...target }; }
  get state() { return this.#state ? structuredClone(this.#state) : undefined; }
  get nodes() { return structuredClone([...this.#nodes.values()]); }

  #accept(observation) {
    const tree = observation?.tree;
    if (!tree || !['full', 'delta'].includes(tree.mode) || typeof tree.reference !== 'string' || typeof tree.sessionID !== 'string') {
      throw new PabloError('Pablo returned an invalid live observation.');
    }
    if (tree.mode === 'full') this.#nodes = new Map(structuredClone(tree.nodes).map(node => [node.id, node]));
    else {
      if (tree.baselineReference !== this.#state?.tree.reference || tree.sessionID !== this.#state?.tree.sessionID) {
        this.#state = undefined; this.#nodes.clear();
        throw new PabloError('The observation baseline does not match this handle. Request full state before acting.');
      }
      for (const change of tree.changes) {
        if (change.kind === 'removed') this.#nodes.delete(change.nodeID);
        else if (change.node?.id === change.nodeID) this.#nodes.set(change.nodeID, structuredClone(change.node));
        else throw new PabloError('Pablo returned an invalid node replacement.');
      }
    }
    this.#state = structuredClone(observation);
    this.#target = { pid: observation.target.pid, sessionID: tree.sessionID,
      ...(observation.target.windowID ? { windowID: observation.target.windowID } : this.#target.windowID ? { windowID: this.#target.windowID } : {}) };
    return observation;
  }

  async #observe(options = {}) {
    const { signal, requestTimeoutMilliseconds, ...observationOptions } = options;
    const observation = { baselineReference: this.#state?.tree.reference, ...observationOptions };
    const result = await this.#client.read('inspect.live', { kind: 'observe', target: this.#target, observation },
      { signal, requestTimeoutMilliseconds });
    return this.#accept(result);
  }

  getState(options) { return this.enqueue(() => this.#observe(options)); }
  async getAXState(options) { return (await this.getState(options)).tree.text; }
  async getScreenshot(options) { return (await this.getState({ ...options, screenshot: true })).screenshot; }
  getAXStateAndScreenshot(options) { return this.getState({ ...options, screenshot: true }); }

  window(windowID) {
    if (this.#nodes.get(windowID)?.role !== 'AXWindow') throw new TypeError('Use a window ID from the current observation.');
    return new PabloApp(this.#client, { ...this.#target, windowID });
  }

  #act(kind, payload, options = {}) {
    return this.enqueue(async () => {
      if (!this.#state) await this.#observe({ signal: options.signal });
      for (const id of [payload.nodeID, payload.fromNodeID, payload.toNodeID].filter(Boolean)) {
        if (!this.#nodes.has(id)) throw new PabloError('The action node is absent from this handle’s current observation.');
      }
      const { signal, requestTimeoutMilliseconds, observation = {}, observe = true, unlockForegroundActions = false } = options;
      const request = { kind, ...payload, target: { ...this.#target, frameReference: this.#state.tree.reference },
        unlockForegroundActions, ...(observe ? { observation: { baselineReference: this.#state.tree.reference, ...observation } } : {}) };
      let result;
      try { result = await this.#client.mutate('action.live', request, { signal, requestTimeoutMilliseconds }); }
      catch (error) { this.#state = undefined; this.#nodes.clear(); throw error; }
      if (result.observation) {
        try { this.#accept(result.observation); }
        catch {
          this.#state = undefined; this.#nodes.clear();
          delete result.observation;
          result.observationFailure = { code: 'invalidObservation', message: 'The action was dispatched, but its observation could not be applied. Request full state before acting.' };
        }
      } else { this.#state = undefined; this.#nodes.clear(); }
      return result;
    });
  }

  click(target, options = {}) { return this.#act('click', { ...actionLocation(target), mouseButton: options.mouseButton ?? 'left', clickCount: options.clickCount ?? 1 }, options); }
  drag(from, to, options = {}) { return this.#act('drag', { ...actionLocation(from, 'fromNodeID', 'fromPoint'), ...actionLocation(to, 'toNodeID', 'toPoint'), duration: options.duration ?? 0.5 }, options); }
  scroll(direction, amount = 3, options = {}) { return this.#act('scroll', { scrollDirection: direction, scrollAmount: amount, ...(options.target ? actionLocation(options.target) : {}) }, options); }
  typeText(text, options = {}) { return this.#act('type', { text, nodeID: options.nodeID }, options); }
  key(key, modifiers = [], options) { return this.#act('key', { key, modifiers }, options); }
  perform(nodeID, accessibilityAction, options) { return this.#act('perform', { nodeID, accessibilityAction }, options); }
  selectText(nodeID, text, options = {}) { return this.#act('selectText', { nodeID, text,
    selection: { prefix: options.prefix, suffix: options.suffix, selectionType: options.selectionType ?? 'text' } }, options); }
  setValue(nodeID, text, options) { return this.#act('setValue', { nodeID, text }, options); }
  paste(text, options = {}) { return this.#act('paste', { text, nodeID: options.nodeID,
    pasteFormat: options.format ?? 'text', plainText: options.plainText }, options); }
}

export class PabloTab extends SerialHandle {
  #client;
  #tabID;
  #state;
  constructor(client, tabID) { super(); this.#client = client; this.#tabID = tabID; }
  get state() { return this.#state ? structuredClone(this.#state) : undefined; }
  async #observe(options = {}) {
    const { signal, requestTimeoutMilliseconds, ...query } = options;
    const state = await this.#client.read('safari.dom', { ...query, kind: 'dumpAccessibilityTree', tabID: this.#tabID }, { signal, requestTimeoutMilliseconds });
    if (typeof state.documentGeneration !== 'string') throw new PabloError('Safari returned no document generation.');
    this.#state = state;
    return structuredClone(state);
  }
  getState(options) { return this.enqueue(() => this.#observe(options)); }
  #act(kind, target, value, options = {}) {
    return this.enqueue(async () => {
      if (!this.#state) await this.#observe({ signal: options.signal });
      const documentGeneration = this.#state.documentGeneration;
      const location = typeof target === 'string' ? { nodeID: target } : target;
      if (!location || Object.keys(location).length !== 1 || !(location.nodeID || location.selector)) {
        throw new TypeError('Use a Safari node ID or an explicit {selector} target.');
      }
      let result;
      try { result = await this.#client.mutate('safari.dom', { kind, ...location, value, tabID: this.#tabID, documentGeneration }, options); }
      catch (error) { this.#state = undefined; throw error; }
      this.#state = undefined;
      if (options.observe !== false) {
        try { result.observation = await this.#observe({ documentGeneration, signal: options.signal }); }
        catch (error) { result.observationFailure = { code: error.failure?.code ?? 'failed', message: 'Safari action dispatched; fresh document state is unavailable. Inspect before acting again.' }; }
      }
      return result;
    });
  }
  click(target, options) { return this.#act('click', target, undefined, options); }
  focus(target, options) { return this.#act('focus', target, undefined, options); }
  setValue(target, value, options) { return this.#act('setValue', target, value, options); }
  scrollIntoView(target, options) { return this.#act('scrollIntoView', target, undefined, options); }
}
