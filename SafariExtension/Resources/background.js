const NATIVE_APPLICATION = "com.ramon.pablo";
const COMMAND_MESSAGE = "dom-command";
const RRWEB_MESSAGE = "pablo-rrweb";
const activeRecordings = new Map();
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

browser.action.onClicked.addListener(async (tab) => {
  if (!tab.id) return;
  try {
    await browser.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => true,
    });
    await browser.action.setBadgeBackgroundColor({ tabId: tab.id, color: "#1769FF" });
    await browser.action.setBadgeText({ tabId: tab.id, text: "ON" });
    await browser.action.setTitle({ tabId: tab.id, title: "Pablo can control this tab until it navigates" });
  } catch (error) {
    await browser.action.setBadgeBackgroundColor({ tabId: tab.id, color: "#B42318" });
    await browser.action.setBadgeText({ tabId: tab.id, text: "!" });
  }
});

browser.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading" || changeInfo.url) {
    reportInterruptedRecording(tabId, "The Safari tab navigated while rrweb recording was active.");
    browser.action.setBadgeText({ tabId, text: "" });
    browser.action.setTitle({ tabId, title: "Unlock this tab for Pablo" });
  }
});

browser.tabs.onRemoved.addListener((tabId) => {
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
  const port = browser.runtime.connectNative(NATIVE_APPLICATION);
  port.onMessage.addListener(async (message) => {
    if (message?.name !== COMMAND_MESSAGE || typeof message.command !== "string") return;
    const response = await handleSerializedCommand(message.command);
    try {
      await browser.runtime.sendNativeMessage(NATIVE_APPLICATION, response);
    } catch (_) {
      // The containing app times out and reports a closed bridge if delivery fails.
    }
  });
  port.onDisconnect.addListener(() => setTimeout(connectNativePort, 500));
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
    const results = await browser.scripting.executeScript({
      target: { tabId: tab.id },
      func: executeDOMCommand,
      args: [command],
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
      ? " Click Pablo’s Safari toolbar button on the tab, then retry."
      : "";
    return nativeResponse(command.id, encodeResponse({
      id: command.id,
      success: false,
      error: `${detail}${activeTabHint}`,
    }));
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
      const results = await browser.scripting.executeScript({
        target: { tabId: tab.id },
        func: () => ({ title: document.title, url: location.href }),
      });
      const metadata = results?.[0]?.result;
      if (!metadata) continue;
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
  const state = { count: 0, truncated: false };

  function clipped(value, length = 2048) {
    if (value == null) return undefined;
    const string = String(value);
    return string.length > length ? `${string.slice(0, length)}…` : string;
  }

  function cssEscape(value) {
    if (globalThis.CSS?.escape) return CSS.escape(value);
    return String(value).replace(/[^a-zA-Z0-9_-]/g, (character) => `\\${character}`);
  }

  function nodeID(element) {
    if (element.id) return `#${cssEscape(element.id)}`;
    const parts = [];
    let current = element;
    while (current && current.nodeType === Node.ELEMENT_NODE && current !== document.documentElement) {
      let part = current.localName;
      const parent = current.parentElement;
      if (parent) {
        const siblings = Array.from(parent.children).filter((child) => child.localName === current.localName);
        if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(current) + 1})`;
      }
      parts.unshift(part);
      current = parent;
    }
    parts.unshift("html");
    return parts.join(" > ");
  }

  function elementForCommand() {
    const selector = command.selector || command.nodeID;
    if (!selector) throw new Error("This command requires selector or nodeID.");
    let element;
    try {
      element = document.querySelector(selector);
    } catch (_) {
      throw new Error(`Invalid selector: ${selector}`);
    }
    if (!element) throw new Error(`No DOM element matches ${selector}. Dump a fresh tree and retry.`);
    return element;
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

  function accessibleName(element) {
    const direct = element.getAttribute("aria-label");
    if (direct) return clipped(direct.trim());
    const labelledBy = element.getAttribute("aria-labelledby");
    if (labelledBy) {
      const text = labelledBy.split(/\s+/).map((id) => document.getElementById(id)?.textContent || "").join(" ").trim();
      if (text) return clipped(text);
    }
    if (element.labels?.length) {
      const text = Array.from(element.labels).map((label) => label.textContent || "").join(" ").trim();
      if (text) return clipped(text);
    }
    const alternate = element.getAttribute("alt") || element.getAttribute("title") || element.getAttribute("placeholder");
    if (alternate) return clipped(alternate.trim());
    if (["button", "a", "summary", "option"].includes(element.localName)) {
      const text = element.innerText?.trim();
      if (text) return clipped(text);
    }
    return undefined;
  }

  function stateAttributes(element) {
    const states = {};
    for (const name of ["checked", "selected", "expanded", "pressed", "current", "required", "invalid", "readonly"]) {
      const value = element.getAttribute(`aria-${name}`);
      if (value != null) states[name] = value;
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
    if (state.count >= maximumNodes || depth > maximumDepth) {
      state.truncated = true;
      return undefined;
    }
    if (node.nodeType === Node.TEXT_NODE) {
      const text = node.textContent?.replace(/\s+/g, " ").trim();
      return text ? { type: "text", text: clipped(text, 512) } : undefined;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return undefined;
    const element = node;
    if (!command.includeHidden && isHidden(element)) return undefined;
    state.count += 1;
    const attributes = {};
    for (const attribute of element.attributes) {
      const lower = attribute.name.toLowerCase();
      if (lower === "value" && (element.getAttribute("type") || "").toLowerCase() === "password") {
        attributes[attribute.name] = "[redacted]";
      } else if (!lower.startsWith("on")) {
        attributes[attribute.name] = clipped(attribute.value, 1024);
      }
    }
    return {
      type: "element",
      nodeID: nodeID(element),
      tag: element.localName,
      attributes,
      children: Array.from(element.childNodes).map((child) => visitDOM(child, depth + 1)).filter(Boolean),
    };
  }

  function visitAccessibility(element, depth) {
    if (state.count >= maximumNodes || depth > maximumDepth) {
      state.truncated = true;
      return [];
    }
    if (!command.includeHidden && isHidden(element)) return [];
    const children = Array.from(element.children).flatMap((child) => visitAccessibility(child, depth + 1));
    const role = element.getAttribute("role")?.split(/\s+/)[0] || implicitRole(element);
    const name = accessibleName(element);
    const meaningful = element === document.documentElement || role || name || element.tabIndex >= 0;
    if (!meaningful) return children;
    state.count += 1;
    return [{
      nodeID: nodeID(element),
      role: element === document.documentElement ? "document" : (role || "generic"),
      name,
      states: stateAttributes(element),
      frame: geometry(element),
      children,
    }];
  }

  try {
    let payload;
    switch (command.kind) {
      case 1:
        payload = {
          kind: "dom",
          url: location.href,
          title: document.title,
          root: visitDOM(document.documentElement, 0),
          nodeCount: state.count,
          truncated: state.truncated,
        };
        break;
      case 2:
        payload = {
          kind: "accessibility",
          source: "dom-derived",
          url: location.href,
          title: document.title,
          root: visitAccessibility(document.documentElement, 0)[0],
          nodeCount: state.count,
          truncated: state.truncated,
        };
        break;
      case 3: {
        const element = elementForCommand();
        element.click();
        payload = { action: "click", nodeID: nodeID(element) };
        break;
      }
      case 4: {
        const element = elementForCommand();
        element.focus({ preventScroll: true });
        payload = { action: "focus", nodeID: nodeID(element) };
        break;
      }
      case 5: {
        const element = elementForCommand();
        if (!("value" in element)) throw new Error("The selected element has no settable value.");
        const prototype = Object.getPrototypeOf(element);
        const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
        if (setter) setter.call(element, command.value || "");
        else element.value = command.value || "";
        element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: null }));
        element.dispatchEvent(new Event("change", { bubbles: true }));
        payload = { action: "setValue", nodeID: nodeID(element), characterCount: (command.value || "").length };
        break;
      }
      case 6: {
        const element = elementForCommand();
        element.scrollIntoView({ block: "center", inline: "center", behavior: "auto" });
        payload = { action: "scrollIntoView", nodeID: nodeID(element) };
        break;
      }
      default:
        throw new Error(`Unsupported DOM command kind ${command.kind}.`);
    }
    return { success: true, payload };
  } catch (error) {
    return { success: false, error: String(error?.message || error) };
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
  output.push(...bytes);
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
