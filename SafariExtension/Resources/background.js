const NATIVE_APPLICATION = "com.semistrict.pablo";
const COMMAND_MESSAGE = "dom-command";
const RRWEB_MESSAGE = "pablo-rrweb";
const activeRecordings = new Map();
// Safari can retain activeTab across same-origin navigation. Pablo grants one Document.
const tabGrants = new Map();
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
let nativePort;
let nativeReconnectTimer;
let nativeHeartbeatTimer;

browser.action.onClicked.addListener(async (tab) => {
  if (!tab.id) return;
  connectNativePort();
  const token = crypto.randomUUID();
  tabGrants.set(tab.id, token);
  try {
    await browser.scripting.executeScript({
      target: { tabId: tab.id },
      func: (token) => {
        globalThis.__pabloTabGrant = { document, token };
        return true;
      },
      args: [token],
    });
    if (tabGrants.get(tab.id) !== token) return;
    await browser.action.setBadgeBackgroundColor({ tabId: tab.id, color: "#1769FF" });
    await browser.action.setBadgeText({ tabId: tab.id, text: "ON" });
    await browser.action.setTitle({ tabId: tab.id, title: "Pablo can control this tab until it navigates" });
  } catch (error) {
    if (tabGrants.get(tab.id) !== token) return;
    tabGrants.delete(tab.id);
    await browser.action.setBadgeBackgroundColor({ tabId: tab.id, color: "#B42318" });
    await browser.action.setBadgeText({ tabId: tab.id, text: "!" });
  }
});

browser.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading" || changeInfo.url) {
    tabGrants.delete(tabId);
    reportInterruptedRecording(tabId, "The Safari tab navigated while rrweb recording was active.");
    browser.action.setBadgeText({ tabId, text: "" });
    browser.action.setTitle({ tabId, title: "Unlock this tab for Pablo" });
  }
});

browser.tabs.onRemoved.addListener((tabId) => {
  tabGrants.delete(tabId);
  reportInterruptedRecording(tabId, "The Safari tab closed while rrweb recording was active.");
});

function reportInterruptedRecording(tabID, error) {
  const recordingID = activeRecordings.get(tabID);
  if (!recordingID) return;
  activeRecordings.delete(tabID);
  void browser.runtime.sendNativeMessage(NATIVE_APPLICATION, {
    kind: "rrweb-error",
    recordingID,
    tabID,
    error,
  });
}

function connectNativePort() {
  if (nativePort) return;
  if (nativeReconnectTimer) {
    clearTimeout(nativeReconnectTimer);
    nativeReconnectTimer = undefined;
  }
  try {
    const port = browser.runtime.connectNative(NATIVE_APPLICATION);
    nativePort = port;
    port.onMessage.addListener(async (message) => {
      const command = globalThis.pabloNativeCommandMessage(message, COMMAND_MESSAGE);
      if (!command) return;
      const response = await handleSerializedCommand(command);
      try {
        await browser.runtime.sendNativeMessage(NATIVE_APPLICATION, response);
      } catch (_) {
        // The containing app times out and reports a closed bridge if delivery fails.
      }
    });
    port.onDisconnect.addListener(() => {
      if (nativePort !== port) return;
      nativePort = undefined;
      clearTimeout(nativeHeartbeatTimer);
      nativeHeartbeatTimer = undefined;
      scheduleNativeReconnect();
    });
    maintainNativePort(port);
  } catch (_) {
    scheduleNativeReconnect();
  }
}

function maintainNativePort(port) {
  if (nativePort !== port) return;
  try {
    // Safari may unload an idle event page without waking it for dispatchMessage.
    // Port traffic keeps the enabled native bridge reachable without reading a page.
    port.postMessage({ kind: "bridge-ping" });
    nativeHeartbeatTimer = setTimeout(() => maintainNativePort(port), 20000);
  } catch (_) {
    nativePort = undefined;
    nativeHeartbeatTimer = undefined;
    try { port.disconnect(); } catch (_) {}
    scheduleNativeReconnect();
  }
}

function scheduleNativeReconnect() {
  if (nativeReconnectTimer) return;
  nativeReconnectTimer = setTimeout(() => {
    nativeReconnectTimer = undefined;
    connectNativePort();
  }, 1000);
}

connectNativePort();

browser.runtime.onMessage.addListener((message, sender) => {
  if (message?.type === `${RRWEB_MESSAGE}-events`) {
    return browser.runtime.sendNativeMessage(NATIVE_APPLICATION, {
      kind: "rrweb-events",
      recordingID: message.recordingID,
      sequence: message.sequence,
      tabID: sender.tab?.id,
      events: message.events,
    });
  }
  if (message?.type === `${RRWEB_MESSAGE}-error`) {
    return browser.runtime.sendNativeMessage(NATIVE_APPLICATION, {
      kind: "rrweb-error",
      recordingID: message.recordingID,
      tabID: sender.tab?.id,
      error: message.error,
    });
  }
  return undefined;
});

async function handleSerializedCommand(base64) {
  let command;
  try {
    command = decodeCommand(fromBase64(base64));
  } catch (error) {
    return nativeResponse("", encodeResponse({ id: "", success: false, error: `Malformed protobuf command: ${error}` }));
  }

  try {
    if (command.kind === 7) {
      return nativeResponse(command.id, encodeResponse({
        id: command.id,
        success: true,
        payload: { kind: "tabs", tabs: await accessibleActiveTabs() },
      }));
    }
    if (command.kind >= 8 && command.kind <= 12) {
      const result = await handleRRWebCommand(command);
      return nativeResponse(command.id, encodeResponse({
        id: command.id,
        success: true,
        payload: result,
      }));
    }
    const tab = command.tabID
      ? await browser.tabs.get(command.tabID)
      : (await browser.tabs.query({ active: true, currentWindow: true }))[0];
    if (!tab?.id) throw new Error("Safari has no active tab.");
    const accessToken = await requireTabAccess(tab.id);
    const results = await browser.scripting.executeScript({
      target: { tabId: tab.id },
      func: executeDOMCommand,
      args: [{ ...command, accessToken }],
    });
    const result = results?.[0]?.result;
    if (!result) throw new Error("The active tab did not return a result.");
    return nativeResponse(command.id, encodeResponse({
      id: command.id,
      success: result.success === true,
      payload: result.payload,
      error: result.error,
    }));
  } catch (error) {
    const detail = String(error?.message || error);
    const activeTabHint = detail.toLowerCase().includes("permission")
      ? " Inspect the current tab grant and page state before deciding on another command."
      : "";
    return nativeResponse(command.id, encodeResponse({
      id: command.id,
      success: false,
      error: `${detail}${activeTabHint}`,
      payload: error?.pabloErrorCode === "permissionRequired"
        ? { errorCode: "permissionRequired", dispatchStatus: "notDispatched", humanAction: detail }
        : undefined,
    }));
  }
}

async function requireTabAccess(tabID) {
  // Probe access before submitting a DOM action or recorder command. A later transport
  // failure still remains outcome-unknown because the requested action may have run.
  try {
    const token = tabGrants.get(tabID);
    if (!token) throw new Error("No tab grant");
    const result = await browser.scripting.executeScript({
      target: { tabId: tabID },
      func: (token) => globalThis.__pabloTabGrant?.document === document && globalThis.__pabloTabGrant.token === token,
      args: [token],
    });
    if (result?.[0]?.result !== true || tabGrants.get(tabID) !== token) throw new Error("No access observation");
    return token;
  } catch (_) {
    const error = new Error('Safari cannot access the intended tab. Make it active and click "Unlock this tab for Pablo" in the toolbar, then handle any Safari permission prompt.');
    error.pabloErrorCode = "permissionRequired";
    throw error;
  }
}

async function handleRRWebCommand(command) {
  if (command.kind === 12 && !command.tabID) {
    const tabs = await accessibleActiveTabs();
    const recordings = [];
    for (const tab of tabs) {
      try {
        const status = await browser.tabs.sendMessage(tab.id, {
          type: RRWEB_MESSAGE,
          command: "status",
          accessToken: await requireTabAccess(tab.id),
        });
        if (status?.recordingID) recordings.push({ ...status, tabID: tab.id });
      } catch (_) {
        // A tab without the injected recorder has no active rrweb recording.
      }
    }
    return { kind: "rrwebStatus", recordings };
  }

  if (!command.tabID) throw new Error("This rrweb command requires a tabID.");
  const commandNames = {
    8: "start",
    9: "pause",
    10: "resume",
    11: "stop",
    12: "status",
  };
  const commandName = commandNames[command.kind];
  const accessToken = await requireTabAccess(command.tabID);
  if (commandName === "start") {
    await browser.scripting.executeScript({
      target: { tabId: command.tabID },
      files: ["rrweb-recorder.js"],
    });
  }
  const result = await browser.tabs.sendMessage(command.tabID, {
    type: RRWEB_MESSAGE,
    command: commandName,
    recordingID: command.recordingID,
    accessToken,
  });
  if (commandName === "start") activeRecordings.set(command.tabID, command.recordingID);
  if (commandName === "stop") activeRecordings.delete(command.tabID);
  return { kind: "rrwebStatus", tabID: command.tabID, ...result };
}

async function accessibleActiveTabs() {
  const tabs = await browser.tabs.query({ active: true });
  const accessible = [];
  for (const tab of tabs) {
    if (!tab.id) continue;
    try {
      const token = await requireTabAccess(tab.id);
      const results = await browser.scripting.executeScript({
        target: { tabId: tab.id },
        func: (token) => globalThis.__pabloTabGrant?.document === document && globalThis.__pabloTabGrant.token === token
          ? { title: document.title, url: location.href } : null,
        args: [token],
      });
      const metadata = results?.[0]?.result;
      if (!metadata || tabGrants.get(tab.id) !== token) continue;
      accessible.push({
        id: tab.id,
        windowID: tab.windowId,
        title: metadata.title || "Untitled tab",
        url: metadata.url,
      });
    } catch (_) {
      // Only tabs with a current activeTab grant are listed.
    }
  }
  return accessible;
}

function nativeResponse(id, bytes) {
  return { id, response: toBase64(bytes) };
}

function executeDOMCommand(command) {
  const maximumNodes = Math.max(1, Math.min(command.maxNodes || 2000, 10000));
  const maximumDepth = Math.max(1, Math.min(command.maxDepth || 20, 50));
  const maximumBytes = 1024 * 1024;
  const state = { count: 0, visited: 0, bytes: 16384, truncated: false, byteBudgetReached: false };
  const encoder = new TextEncoder();

  function clipped(value, length = 2048) {
    if (value == null) return undefined;
    const string = String(value);
    if (string.length <= length) return string;
    state.truncated = true;
    return `${string.slice(0, length)}…`;
  }

  // Isolated-world state follows this exact Document and never reuses an expired ID.
  const documentKey = "__pabloDOMIdentity";
  let identity = globalThis[documentKey];
  if (!identity || identity.document !== document) {
    identity = { document, generation: crypto.randomUUID(), nextID: 0, ids: new WeakMap(), nodes: new Map() };
    globalThis[documentKey] = identity;
    if (!globalThis.__pabloDOMPageShowInstalled) {
      globalThis.__pabloDOMPageShowInstalled = true;
      addEventListener("pageshow", (event) => {
        if (event.persisted) globalThis[documentKey] = undefined;
      });
    }
  }
  function nodeID(node) {
    let id = identity.ids.get(node);
    if (!id || !identity.nodes.has(id)) {
      id = `DOM-${identity.generation}:${++identity.nextID}`;
      identity.ids.set(node, id);
      identity.nodes.set(id, new WeakRef(node));
      if (identity.nodes.size > 20000) identity.nodes.delete(identity.nodes.keys().next().value);
    }
    return id;
  }

  function enter(depth) {
    if (state.byteBudgetReached || state.visited >= maximumNodes || depth > maximumDepth) {
      state.truncated = true;
      return false;
    }
    state.visited += 1;
    return true;
  }

  function childrenOf(element, depth, visit) {
    const children = [];
    for (let child = element.firstChild; child; child = child.nextSibling) {
      if (state.byteBudgetReached || state.visited >= maximumNodes || depth + 1 > maximumDepth) {
        state.truncated = true;
        break;
      }
      const result = visit(child, depth + 1);
      if (Array.isArray(result)) children.push(...result);
      else if (result) children.push(result);
    }
    return children;
  }

  function elementForCommand() {
    if (command.nodeID) {
      const node = identity.nodes.get(command.nodeID)?.deref();
      if (!node || !node.isConnected || node.nodeType !== Node.ELEMENT_NODE) {
        throw staleContext("This node reference is unavailable. Inspect the current document before acting.");
      }
      return node;
    }
    const selector = command.selector;
    if (!selector) throw new Error("This command requires selector or nodeID.");
    let element;
    try {
      element = document.querySelector(selector);
    } catch (_) {
      throw new Error("Invalid DOM selector.");
    }
    if (!element) throw new Error("No DOM element matches this selector. Inspect the current document before acting.");
    return element;
  }

  function staleContext(message) {
    const error = new Error(message);
    error.pabloErrorCode = "staleContext";
    return error;
  }

  function isHidden(element) {
    if (element.hidden || element.getAttribute("aria-hidden") === "true") return true;
    const style = getComputedStyle(element);
    return style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse";
  }

  function implicitRole(element) {
    const tag = element.localName;
    if (tag === "a" && element.hasAttribute("href")) return "link";
    if (tag === "button") return "button";
    if (tag === "textarea") return "textbox";
    if (tag === "select") return element.multiple ? "listbox" : "combobox";
    if (tag === "option") return "option";
    if (tag === "img") return "img";
    if (tag === "table") return "table";
    if (tag === "tr") return "row";
    if (tag === "th") return "columnheader";
    if (tag === "td") return "cell";
    if (tag === "ul" || tag === "ol") return "list";
    if (tag === "li") return "listitem";
    if (/^h[1-6]$/.test(tag)) return "heading";
    if (tag === "nav") return "navigation";
    if (tag === "main") return "main";
    if (tag === "form") return "form";
    if (tag === "input") {
      const type = (element.getAttribute("type") || "text").toLowerCase();
      if (["button", "submit", "reset", "image"].includes(type)) return "button";
      if (type === "checkbox") return "checkbox";
      if (type === "radio") return "radio";
      if (type === "range") return "slider";
      if (type === "number") return "spinbutton";
      if (type !== "hidden") return "textbox";
    }
    return undefined;
  }

  function boundedLabelText(root) {
    let result = "";
    let remaining = 32;
    function read(node, depth) {
      if (remaining-- <= 0 || result.length >= 512) { state.truncated = true; return; }
      if (!enter(depth)) return;
      if (node.nodeType === Node.TEXT_NODE) {
        result += node.substringData(0, 512 - result.length);
      } else if (node.nodeType === Node.ELEMENT_NODE && !isHidden(node)) {
        for (let child = node.firstChild; child; child = child.nextSibling) {
          if (remaining <= 0 || result.length >= 512 || state.visited >= maximumNodes) {
            state.truncated = true;
            break;
          }
          read(child, depth + 1);
        }
      }
    }
    if (root) read(root, 0);
    return result.replace(/\s+/g, " ").trim();
  }

  function accessibleName(element) {
    const direct = clipped(element.getAttribute("aria-label"), 512);
    if (direct) return direct.trim();
    const labelledBy = clipped(element.getAttribute("aria-labelledby"), 512);
    if (labelledBy) {
      const ids = labelledBy.split(/\s+/).slice(0, 8);
      const text = ids.map((id) => boundedLabelText(document.getElementById(id))).join(" ");
      if (text.trim()) return clipped(text.trim(), 512);
    }
    if (element.labels?.length) {
      let text = "";
      for (let index = 0; index < Math.min(element.labels.length, 8) && text.length < 512; index++) {
        text += `${boundedLabelText(element.labels[index])} `;
      }
      if (text.trim()) return clipped(text.trim(), 512);
    }
    const alternate = element.getAttribute("alt") || element.getAttribute("title") || element.getAttribute("placeholder");
    return alternate ? clipped(alternate, 512).trim() : undefined;
  }

  function emit(node) {
    // Charge each node once, excluding descendants. Reserve covers wrapper metadata.
    const cost = encoder.encode(JSON.stringify(node)).length + 2;
    if (state.bytes + cost > maximumBytes) {
      state.truncated = true;
      state.byteBudgetReached = true;
      return undefined;
    }
    state.bytes += cost;
    state.count += 1;
    return node;
  }

  function stateAttributes(element) {
    const states = {};
    for (const name of ["checked", "selected", "expanded", "pressed", "current", "required", "invalid", "readonly"]) {
      const value = element.getAttribute(`aria-${name}`);
      if (value != null) states[name] = clipped(value, 512);
    }
    if (element.matches(":disabled") || element.getAttribute("aria-disabled") === "true") states.disabled = true;
    if (document.activeElement === element) states.focused = true;
    if ("value" in element) {
      const type = (element.getAttribute("type") || "").toLowerCase();
      states.value = type === "password" ? "[redacted]" : clipped(element.value, 1024);
    }
    return states;
  }

  function geometry(element) {
    const rect = element.getBoundingClientRect();
    return {
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
    };
  }

  function visitDOM(node, depth) {
    if (!enter(depth)) return undefined;
    if (node.nodeType === Node.TEXT_NODE) {
      const text = node.substringData(0, 512).replace(/\s+/g, " ");
      if (node.length > 512) state.truncated = true;
      return text.trim() ? emit({ type: "text", nodeID: nodeID(node), text }) : undefined;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return undefined;
    const element = node;
    if (!command.includeHidden && isHidden(element)) return undefined;
    const attributes = Object.create(null);
    for (let index = 0; index < Math.min(element.attributes.length, 32); index++) {
      const attribute = element.attributes[index];
      const name = clipped(attribute.name, 128);
      const lower = name.toLowerCase();
      if (lower === "value" && (element.getAttribute("type") || "").toLowerCase() === "password") {
        attributes[name] = "[redacted]";
      } else if (!lower.startsWith("on")) {
        attributes[name] = clipped(attribute.value, 1024);
      }
    }
    if (element.attributes.length > 32) state.truncated = true;
    const result = emit({ type: "element", nodeID: nodeID(element), tag: clipped(element.localName, 128), attributes, children: [] });
    if (result) result.children = childrenOf(element, depth, visitDOM);
    return result;
  }

  function visitAccessibility(element, depth) {
    if (!enter(depth)) return [];
    if (element.nodeType === Node.TEXT_NODE) {
      const text = element.substringData(0, 512).replace(/\s+/g, " ");
      if (element.length > 512) state.truncated = true;
      const result = text.trim() ? emit({ nodeID: nodeID(element), role: "text", text }) : undefined;
      return result ? [result] : [];
    }
    if (element.nodeType !== Node.ELEMENT_NODE) return [];
    if (!command.includeHidden && isHidden(element)) return [];
    const role = clipped(element.getAttribute("role"), 128)?.split(/\s+/)[0] || implicitRole(element);
    const name = accessibleName(element);
    const meaningful = element === document.documentElement || role || name || element.tabIndex >= 0;
    if (!meaningful) return childrenOf(element, depth, visitAccessibility);
    const result = emit({
      nodeID: nodeID(element),
      role: element === document.documentElement ? "document" : (role || "generic"),
      name,
      states: stateAttributes(element),
      frame: geometry(element),
      children: [],
    });
    if (!result) return [];
    result.children = childrenOf(element, depth, visitAccessibility);
    if (!result.name && ["button", "link", "heading", "option", "cell", "columnheader"].includes(result.role)) {
      let label = "";
      let remaining = 64;
      function collect(nodes) {
        for (const node of nodes) {
          if (remaining-- <= 0 || label.length >= 512) { state.truncated = true; break; }
          if (node.text) label += node.text.slice(0, 512 - label.length);
          else if (node.children) collect(node.children);
        }
      }
      collect(result.children);
      label = label.trim();
      const cost = encoder.encode(JSON.stringify({ name: label })).length;
      if (label && state.bytes + cost <= maximumBytes) {
        result.name = label;
        state.bytes += cost;
      } else if (label) {
        state.truncated = true;
        state.byteBudgetReached = true;
      }
    }
    return [result];
  }

  let dispatchStarted = false;
  try {
    if (!command.accessToken || globalThis.__pabloTabGrant?.document !== document ||
        globalThis.__pabloTabGrant.token !== command.accessToken) {
      const error = new Error('This document is locked. Click "Unlock this tab for Pablo" in Safari.');
      error.pabloErrorCode = "permissionRequired";
      throw error;
    }
    const mutation = command.kind >= 3 && command.kind <= 6;
    if ((mutation && !command.documentGeneration) ||
        (command.documentGeneration && command.documentGeneration.toLowerCase() !== identity.generation.toLowerCase())) {
      throw staleContext("The document context is stale or missing. Inspect the current document before acting.");
    }
    let payload;
    switch (command.kind) {
      case 1:
        payload = {
          kind: "dom",
          url: clipped(location.href, 2048),
          title: clipped(document.title, 1024),
          root: visitDOM(document.documentElement, 0),
          nodeCount: state.count,
          visitedNodeCount: state.visited,
          byteBudget: maximumBytes,
          byteBudgetReached: state.byteBudgetReached,
          truncated: state.truncated,
        };
        break;
      case 2:
        payload = {
          kind: "accessibility",
          source: "dom-derived",
          url: clipped(location.href, 2048),
          title: clipped(document.title, 1024),
          root: visitAccessibility(document.documentElement, 0)[0],
          nodeCount: state.count,
          visitedNodeCount: state.visited,
          byteBudget: maximumBytes,
          byteBudgetReached: state.byteBudgetReached,
          truncated: state.truncated,
        };
        break;
      case 3: {
        const element = elementForCommand();
        dispatchStarted = true;
        element.click();
        payload = { action: "click", nodeID: nodeID(element) };
        break;
      }
      case 4: {
        const element = elementForCommand();
        dispatchStarted = true;
        element.focus({ preventScroll: true });
        payload = { action: "focus", nodeID: nodeID(element) };
        break;
      }
      case 5: {
        const element = elementForCommand();
        if (!("value" in element)) throw new Error("The selected element has no settable value.");
        const prototype = Object.getPrototypeOf(element);
        const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
        dispatchStarted = true;
        if (setter) setter.call(element, command.value || "");
        else element.value = command.value || "";
        element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: null }));
        element.dispatchEvent(new Event("change", { bubbles: true }));
        payload = { action: "setValue", nodeID: nodeID(element), characterCount: (command.value || "").length };
        break;
      }
      case 6: {
        const element = elementForCommand();
        dispatchStarted = true;
        element.scrollIntoView({ block: "center", inline: "center", behavior: "auto" });
        payload = { action: "scrollIntoView", nodeID: nodeID(element) };
        break;
      }
      default:
        throw new Error(`Unsupported DOM command kind ${command.kind}.`);
    }
    payload.documentGeneration = identity.generation;
    if (mutation) {
      payload.dispatchStatus = "dispatched";
      payload.effectStatus = "unverified";
    }
    return { success: true, payload };
  } catch (error) {
    return { success: false, payload: { documentGeneration: identity.generation, errorCode: error?.pabloErrorCode, dispatchStatus: dispatchStarted ? "attempted" : "notDispatched", effectStatus: "unverified" }, error: clipped(error?.message || error, 2048) };
  }
}

function decodeCommand(bytes) {
  const reader = protobufReader(bytes);
  const command = { id: "", kind: 0, includeHidden: false, maxNodes: 0, maxDepth: 0 };
  while (!reader.done()) {
    const tag = reader.varint();
    const field = tag >>> 3;
    const wire = tag & 7;
    if (field === 1) command.id = reader.string();
    else if (field === 2) command.kind = reader.varint();
    else if (field === 3) command.selector = reader.string();
    else if (field === 4) command.nodeID = reader.string();
    else if (field === 5) command.value = reader.string();
    else if (field === 6) command.includeHidden = reader.varint() !== 0;
    else if (field === 7) command.maxNodes = reader.varint();
    else if (field === 8) command.maxDepth = reader.varint();
    else if (field === 9) command.tabID = reader.varint();
    else if (field === 10) command.recordingID = reader.string();
    else if (field === 11) command.documentGeneration = reader.string();
    else reader.skip(wire);
  }
  if (!command.id) throw new Error("missing command id");
  return command;
}

function encodeResponse(response) {
  const output = [];
  writeString(output, 1, response.id || "");
  writeVarintField(output, 2, response.success ? 1 : 0);
  if (response.payload !== undefined) writeBytes(output, 3, textEncoder.encode(JSON.stringify(response.payload)));
  if (response.error) writeString(output, 4, response.error);
  return new Uint8Array(output);
}

function protobufReader(bytes) {
  let offset = 0;
  return {
    done: () => offset >= bytes.length,
    varint() {
      let value = 0;
      let shift = 0;
      while (offset < bytes.length && shift < 35) {
        const byte = bytes[offset++];
        value += (byte & 0x7f) * (2 ** shift);
        if ((byte & 0x80) === 0) return value;
        shift += 7;
      }
      throw new Error("invalid varint");
    },
    bytes() {
      const length = this.varint();
      if (offset + length > bytes.length) throw new Error("truncated bytes");
      const value = bytes.slice(offset, offset + length);
      offset += length;
      return value;
    },
    string() { return textDecoder.decode(this.bytes()); },
    skip(wire) {
      if (wire === 0) this.varint();
      else if (wire === 2) this.bytes();
      else if (wire === 1) offset += 8;
      else if (wire === 5) offset += 4;
      else throw new Error(`unsupported wire type ${wire}`);
      if (offset > bytes.length) throw new Error("truncated field");
    },
  };
}

function writeVarint(output, value) {
  let remaining = Number(value);
  while (remaining > 127) {
    output.push((remaining & 0x7f) | 0x80);
    remaining = Math.floor(remaining / 128);
  }
  output.push(remaining);
}

function writeVarintField(output, field, value) {
  writeVarint(output, field << 3);
  writeVarint(output, value);
}

function writeBytes(output, field, bytes) {
  writeVarint(output, (field << 3) | 2);
  writeVarint(output, bytes.length);
  // Dumps may approach 1 MiB, beyond the engine's function-argument limit.
  for (const byte of bytes) output.push(byte);
}

function writeString(output, field, value) {
  writeBytes(output, field, textEncoder.encode(value));
}

function fromBase64(value) {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function toBase64(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}
