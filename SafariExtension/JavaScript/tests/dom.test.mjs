import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import vm from 'node:vm';

const background = await readFile(new URL('../../Resources/background.js', import.meta.url), 'utf8');
const injectedSource = background.slice(background.indexOf('function executeDOMCommand('), background.indexOf('\nfunction decodeCommand('));

// This fixture replaces only the browser DOM boundary; commands execute the shipped script.
class TextNode {
  constructor(text) { this.nodeType = 3; this.textContent = text; this.childNodes = []; this.isConnected = true; }
  substringData(start, count) { return this.textContent.slice(start, start + count); }
}
class Element {
  constructor(tag, children = [], attributes = {}) {
    this.nodeType = 1; this.localName = tag; this.childNodes = children;
    this.attributes = Object.entries(attributes).map(([name, value]) => ({ name, value }));
    this.tabIndex = -1; this.isConnected = true; this.clicks = 0;
    children.forEach((child, index) => {
      child.parentElement = this; child.nextSibling = children[index + 1] || null;
    });
  }
  get firstChild() { return this.childNodes[0] || null; }
  get children() { return this.childNodes.filter(child => child.nodeType === 1); }
  get textContent() { return this.childNodes.map(child => child.textContent).join(''); }
  get innerText() { return this.textContent; }
  getAttribute(name) { return this.attributes.find(attribute => attribute.name === name)?.value ?? null; }
  hasAttribute(name) { return this.getAttribute(name) !== null; }
  matches() { return false; }
  getBoundingClientRect() { return { x: 0, y: 0, width: 100, height: 20 }; }
  click() { this.clicks++; }
}
const text = value => new TextNode(value);
const element = (tag, children, attributes) => new Element(tag, children, attributes);
function browser(root) {
  const document = { documentElement: root, title: 'Fixture', activeElement: null, querySelector: () => root.children[0] };
  const context = vm.createContext({ document, location: { href: 'https://example.test/' }, Node: { ELEMENT_NODE: 1, TEXT_NODE: 3 },
    getComputedStyle: node => ({ display: node.getAttribute('hidden') !== null ? 'none' : 'block', visibility: 'visible' }),
    crypto: { randomUUID }, WeakRef, TextEncoder, addEventListener() {} });
  context.__pabloTabGrant = { document, token: "fixture-grant" };
  vm.runInContext(injectedSource, context);
  return { document, replaceDocument: value => { context.document = value; context.__pabloTabGrant = { document: value, token: "fixture-grant" }; }, run: command => context.executeDOMCommand({ accessToken: "fixture-grant", ...command }) };
}
function allNodes(root) { return root ? [root, ...(root.children || []).flatMap(allNodes)] : []; }

test('accessibility dumps retain heading and ordinary prose in reading order', () => {
  const fixture = browser(element('html', [element('body', [
    element('h1', [text('Welcome')]), element('p', [text('Read '), element('em', [text('these')]), text(' instructions.')]),
  ])]));
  const response = fixture.run({ kind: 2 });
  assert.equal(response.success, true);
  const nodes = allNodes(response.payload.root);
  assert.equal(nodes.filter(node => node.role === 'text').map(node => node.text).join(''), 'WelcomeRead these instructions.');
  assert.ok(nodes.some(node => node.role === 'heading'));
});

test('node budgets bound traversal through text, generic, and hidden siblings', () => {
  for (const kind of [1, 2]) {
    for (const child of [() => text('a'), () => element('div'), () => element('div', [], { hidden: '' })]) {
      const root = element('html', Array.from({ length: 1000 }, child));
      let reads = 0;
      root.childNodes.forEach(node => {
        const next = node.nextSibling;
        Object.defineProperty(node, 'nextSibling', { get() { reads++; return next; } });
        Object.defineProperty(node, 'nodeType', { get() { reads++; return node instanceof TextNode ? 3 : 1; } });
      });
      const response = browser(root).run({ kind, maxNodes: 10 });
      assert.equal(response.success, true);
      assert.ok(reads < 100, `traversed ${reads} properties beyond a ten-node budget`);
      assert.ok(allNodes(response.payload.root).length <= 10);
      assert.equal(response.payload.visitedNodeCount, 10);
      assert.equal(response.payload.truncated, true);
    }
  }
});

test('dump output and per-node attributes are bounded and password values stay redacted', () => {
  for (const kind of [1, 2]) {
    const attributes = Object.fromEntries(Array.from({ length: 100 }, (_, i) => [`data-${i}`, '界'.repeat(2000)]));
    const password = element('input', [], { type: 'password', value: 'secret', 'aria-label': 'Password' });
    password.value = 'secret';
    const root = element('html', [password, ...Array.from({ length: 1000 }, () => element('button', [text('Visible prose')], attributes))]);
    const fixture = browser(root);
    fixture.document.title = '界'.repeat(1000000);
    const response = fixture.run({ kind, maxNodes: 10000 });
    assert.equal(response.success, true);
    assert.ok(Buffer.byteLength(JSON.stringify(response)) <= 1024 * 1024);
    assert.ok(!JSON.stringify(response).includes('secret'));
    assert.equal(response.payload.truncated, true);
    assert.ok(allNodes(response.payload.root).every(node => Object.keys(node.attributes || {}).length <= 32));
  }
});

test('accessible names never read unbounded subtree text', () => {
  const button = element('button', [text('Save')]);
  Object.defineProperty(button, 'innerText', { get() { throw new Error('unbounded text read'); } });
  Object.defineProperty(button, 'textContent', { get() { throw new Error('unbounded text read'); } });
  const response = browser(element('html', [button])).run({ kind: 2, maxNodes: 10 });
  assert.equal(response.success, true);
  assert.ok(allNodes(response.payload.root).some(node => node.text === 'Save'));
  assert.equal(allNodes(response.payload.root).find(node => node.role === 'button').name, 'Save');
});

test('DOM actions require the observed document and never reuse a replaced node', () => {
  const button = element('button', [text('Submit')]);
  const fixture = browser(element('html', [button]));
  const first = fixture.run({ kind: 2 });
  const generation = first.payload.documentGeneration;
  assert.match(generation || '', /^[a-f0-9-]{36}$/i);
  const nodeID = allNodes(first.payload.root).find(node => node.role === 'button').nodeID;
  const missingContext = fixture.run({ kind: 3, nodeID });
  assert.equal(missingContext.success, false);
  assert.equal(missingContext.payload.errorCode, 'staleContext');
  assert.equal(missingContext.payload.dispatchStatus, 'notDispatched');
  assert.equal(button.clicks, 0);
  const clicked = fixture.run({ kind: 3, nodeID, documentGeneration: generation });
  assert.equal(clicked.success, true);
  assert.equal(clicked.payload.effectStatus, 'unverified');
  assert.equal(button.clicks, 1);
  button.isConnected = false;
  const removedNode = fixture.run({ kind: 3, nodeID, documentGeneration: generation });
  assert.equal(removedNode.success, false);
  assert.equal(removedNode.payload.errorCode, 'staleContext');
  fixture.document = { ...fixture.document, documentElement: element('html', [element('button')]) };
  fixture.replaceDocument(fixture.document);
  const replacedDocument = fixture.run({ kind: 3, selector: 'button', documentGeneration: generation });
  assert.equal(replacedDocument.success, false);
  assert.equal(replacedDocument.payload.errorCode, 'staleContext');
  assert.equal(fixture.document.documentElement.children[0].clicks, 0);
  const next = fixture.run({ kind: 2 });
  assert.notEqual(next.payload.documentGeneration, generation);
});

test('a DOM command cannot cross into a document without the matching toolbar grant', () => {
  const button = element('button', [text('Submit')]);
  const fixture = browser(element('html', [button]));
  const observed = fixture.run({ kind: 2 });
  const response = fixture.run({ kind: 3, selector: 'button', documentGeneration: observed.payload.documentGeneration, accessToken: 'expired-grant' });
  assert.equal(response.success, false);
  assert.equal(response.payload.errorCode, 'permissionRequired');
  assert.equal(response.payload.dispatchStatus, 'notDispatched');
  assert.equal(button.clicks, 0);
});
