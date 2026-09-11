# Pablo JavaScript control

Use the running Pablo app from Node.js 22 or newer. The client has no dependencies and communicates over Pablo's existing local HTTP socket. Approval, target validation, and privacy permissions remain owned by the app.

Start a persistent JavaScript console from the repository:

```sh
pnpm --dir JavaScript repl
```

The console provides `pablo` and supports top-level `await`. App and tab handles remain available until the console exits. It does not save console history or launch target applications.

For scripts, import the client:

```js
import { Pablo } from './JavaScript/src/index.mjs';

const pablo = await Pablo.connect();
const app = await pablo.app({ bundleIdentifier: 'com.apple.Notes' });
console.log(app.state.tree.text);
console.log(app.nodes); // Materialized nodes, including changes from earlier observations.
```

## Observe and act

`getState()` returns a fresh observation. The first observation is full; later calls request a delta from this handle's last frame. Other clients can inspect the same app without disturbing that baseline. Expired baselines cause an explicit full resynchronization. Use `getState({full: true})` to request full state yourself.

```js
const state = await app.getState();
console.log(state.tree.text); // + additions, ~ changes, - removals, or no changes.

const editor = app.nodes.find(node => node.settableAttributes?.includes('AXValue'));
if (!editor) throw new Error('No supported editable field is visible.');
const result = await app.setValue(editor.id, 'First paragraph\nSecond paragraph');
console.log(result.observation?.tree.text);
```

Native actions include a new observation in the same HTTP call by default. The client serializes calls on each handle and pins the observed process, session, frame, and selected window. It never silently rebinds an expired handle to a restarted application. Create a new handle after inspecting why the old one expired.

`dispatchStatus: "dispatched"` and `effectStatus: "unverified"` mean input was dispatched; inspect the returned state to determine whether the intended result occurred. `settleStatus: "settled"` means the sampled accessibility tree stayed unchanged for the quiet interval. It does not prove a save, submission, or other application outcome. `timedOut` includes the last sampled state. An `observationFailure` preserves the action result and invalidates the handle's cached state.

Use `observation: {quietMilliseconds: 250, timeoutMilliseconds: 2000}` on an action to adjust settling. `getState()` accepts those fields directly. `requestTimeoutMilliseconds` separately controls the transport deadline. `observe: false` skips the post-action observation and invalidates cached state; the next action must obtain fresh state.

## Text and images

```js
await app.selectText(editor.id, 'paragraph', {
  prefix: 'Second ', selectionType: 'cursorAfter'
});

const view = await app.getAXStateAndScreenshot();
console.log(view.tree.text);
const png = Buffer.from(view.screenshot.pngBase64, 'base64');
```

Selection supports exact text matching, adjacent prefix/suffix disambiguation, and cursor placement before or after the match. The observed `selectedTextRange` uses UTF-16 units. Native selection and value replacement require supported, enabled, non-secure text controls. Empty replacement clears a field. Unsupported controls fail without falling back to keystrokes.

Screenshots require Screen Recording permission. They capture the selected window, or the largest available accessible window, without activating the application. Use `app.window(windowID)` to select a window found in the current tree. Each image includes the observation ID, frame reference, window identity, capture timestamps, and desktop geometry. Accessibility and pixels are collected separately and checked for state/geometry changes; they are not an atomic snapshot. Images are capped at 2048 pixels per side and 6 MiB of PNG data.

Native typing, paste, pointer input without AXPress, and keys require `unlockForegroundActions: true`. Set it only when the user has explicitly accepted changing foreground focus. The default remains false.

```js
// The user has explicitly accepted switching focus to this target.
await app.paste('<b>Heading</b><p>First line<br>Second line</p>', {
  nodeID: editor.id,
  format: 'html',
  plainText: 'Heading\nFirst line\nSecond line',
  unlockForegroundActions: true
});
```

Paste supports plain text or HTML with a required plain-text fallback. It materializes the existing clipboard's representations before changing it, then restores them after dispatch, failure, or cancellation. A newer clipboard writer is preserved. Inspect `clipboardRestoration` for `restored`, `preservedNewerContent`, or `failed`. Pablo keeps paste data available for 500 ms after posting the shortcut; a busy application may not consume it within that interval, so verify the resulting field. Clipboard preservation is bounded to 128 items and 32 MiB. This client never prints supplied text; explicit observations can include actual visible field values.

## Safari

```js
const available = await pablo.tabs();
const tab = await pablo.tab(available.tabs[0].id);
console.log(tab.state.root);
// Use a fresh opaque nodeID from this document, or an explicit selector.
const result = await tab.click({ selector: 'button[type="button"]' });
console.log(result.observation?.root);
```

Safari handles use the existing extension commands and document generations. They support click, focus, setValue, scrollIntoView, and accessibility dumps. Each action uses its operation receipt, then the client reads the same document in a second HTTP request within the method call. Navigation or a lost grant produces `observationFailure` without repeating the action. Safari dumps retain their DOM-derived tree representation. The user must enable the extension and unlock the active tab with its toolbar button after navigation.

## Receipts and cancellation

Every mutation gets a new operation ID before dispatch. If its response is lost, the client only looks up that same receipt. It never retries the mutation. An unavailable, expired, pending, or omitted receipt is exposed through `PabloError.operation` and `PabloError.receipt`; inspect state before deciding on another action.

```js
const abort = new AbortController();
try {
  await app.click('an-observed-node-id', { signal: abort.signal });
} catch (error) {
  if (error.operation) console.log(await pablo.receipt(error.operation));
}
```

Aborting a mutation asks the app to cancel that operation. Already-dispatched effects are not rolled back. Large observations are delivered on the executing connection; subsequent receipt lookups may omit responses larger than 256 KiB. Low-level `read()` rejects mutation methods; `mutate()` uses the approved operation wrapper.

Run client tests with `pnpm --dir JavaScript test`. The tests use temporary local sockets and remove them when finished.
