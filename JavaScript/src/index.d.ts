export interface RequestOptions { signal?: AbortSignal; requestTimeoutMilliseconds?: number }
export interface ConnectionOptions { socketPath?: string; timeoutMilliseconds?: number }
export interface ObservationOptions extends RequestOptions {
  baselineReference?: string; full?: boolean; screenshot?: boolean;
  quietMilliseconds?: number; timeoutMilliseconds?: number;
}
export interface Point { x: number; y: number }
export interface Frame extends Point { width: number; height: number }
export interface LiveNode {
  id: string; parentID?: string; childIDs: string[]; depth: number;
  role?: string; subrole?: string; title?: string; label?: string; value?: string;
  identifier?: string; help?: string; enabled?: boolean; focused?: boolean;
  frame?: Frame; actions?: string[]; settableAttributes?: string[];
  selectedTextRange?: { location: number; length: number };
}
export interface TreeChange {
  kind: 'added' | 'updated' | 'removed'; nodeID: string; node?: LiveNode; changedProperties: string[];
}
export interface TreeObservation {
  sessionID: string; reference: string; baselineReference?: string; mode: 'full' | 'delta';
  resyncRequired: boolean; rootID?: string; timestampNs: number; totalNodeCount: number;
  truncated: boolean; nodes: LiveNode[]; changes: TreeChange[]; text: string; textTruncated: boolean;
}
export interface Screenshot {
  observationID: string; frameReference: string; windowID: string; captureWindowID: number;
  frame: Frame; width: number; height: number; mimeType: 'image/png'; pngBase64: string;
  startedAtUptimeNanoseconds: number; finishedAtUptimeNanoseconds: number;
}
export interface LiveObservation {
  id: string; target: { pid: number; bundleIdentifier?: string; applicationName: string; windowID?: string };
  tree: TreeObservation; settleStatus: 'sampled' | 'settled' | 'timedOut';
  sampleCount: number; elapsedMilliseconds: number; screenshot?: Screenshot;
}
export interface ActionOptions extends RequestOptions {
  observe?: boolean; observation?: Omit<ObservationOptions, keyof RequestOptions>;
  unlockForegroundActions?: boolean;
}
export interface ActionResult {
  actionID: string; dispatchStatus: 'dispatched'; effectStatus: 'unverified';
  target?: { pid: number; bundleIdentifier?: string; applicationName: string; sessionID: string; windowID?: string; inspectionFrameReference?: string };
  dispatchMethod?: 'accessibility' | 'foregroundInput' | 'safariDOM';
  characterCount?: number; summary?: string; observation?: LiveObservation;
  observationFailure?: { code: string; message: string };
  clipboardRestoration?: 'restored' | 'preservedNewerContent' | 'failed';
}
export interface Operation { serviceID: string; operationID: string }
export interface Failure { code: string; dispatchStatus: 'notDispatched' | 'outcomeUnknown'; humanAction?: string }
export interface Receipt extends Operation {
  method: string; status: 'awaitingHuman' | 'running' | 'cancellationRequested' | 'completed' | 'rejected' | 'interrupted' | 'outcomeUnknown';
  expiresAt: string; resultOmitted: boolean;
  response?: { id: string; result?: { output?: unknown; [key: string]: unknown }; failure?: Failure; error?: string };
}
export type AppSelector = string | { pid: number; bundleIdentifier?: never; appName?: never }
  | { bundleIdentifier: string; pid?: never; appName?: never } | { appName: string; pid?: never; bundleIdentifier?: never };
export type NodeTarget = string | Point;
export type KeyModifier = 'command' | 'option' | 'control' | 'shift' | 'function';
export interface ServiceInfo { serviceID: string; version?: string; build?: string; methods?: string[]; [key: string]: unknown }
export class PabloError extends Error {
  failure?: Failure; receipt?: Receipt; operation?: Operation;
}
export class Pablo {
  constructor(options?: ConnectionOptions);
  static connect(options?: ConnectionOptions): Promise<Pablo>;
  serviceInfo(options?: RequestOptions): Promise<ServiceInfo>;
  read<T = unknown>(method: string, payload?: object, options?: RequestOptions): Promise<T>;
  mutate<T = ActionResult>(method: string, payload: object, options?: RequestOptions): Promise<T>;
  targets(options?: RequestOptions): Promise<unknown>;
  tabs(options?: RequestOptions): Promise<unknown>;
  receipt(operation: Operation, options?: RequestOptions): Promise<Receipt>;
  cancel(operation: Operation, options?: RequestOptions): Promise<Receipt>;
  app(selector: AppSelector, options?: ObservationOptions): Promise<PabloApp>;
  tab(tabID: number, options?: SafariObservationOptions): Promise<PabloTab>;
}
export class PabloApp {
  readonly state: LiveObservation | undefined;
  readonly nodes: LiveNode[];
  getState(options?: ObservationOptions): Promise<LiveObservation>;
  getAXState(options?: ObservationOptions): Promise<string>;
  getScreenshot(options?: ObservationOptions): Promise<Screenshot | undefined>;
  getAXStateAndScreenshot(options?: ObservationOptions): Promise<LiveObservation>;
  window(windowID: string): PabloApp;
  click(target: NodeTarget, options?: ActionOptions & { mouseButton?: 'left' | 'right' | 'middle'; clickCount?: number }): Promise<ActionResult>;
  drag(from: NodeTarget, to: NodeTarget, options?: ActionOptions & { duration?: number }): Promise<ActionResult>;
  scroll(direction: 'up' | 'down' | 'left' | 'right', amount?: number, options?: ActionOptions & { target?: NodeTarget }): Promise<ActionResult>;
  typeText(text: string, options?: ActionOptions & { nodeID?: string }): Promise<ActionResult>;
  key(key: string, modifiers?: KeyModifier[], options?: ActionOptions): Promise<ActionResult>;
  perform(nodeID: string, action: string, options?: ActionOptions): Promise<ActionResult>;
  selectText(nodeID: string, text: string, options?: ActionOptions & { prefix?: string; suffix?: string; selectionType?: 'text' | 'cursorBefore' | 'cursorAfter' }): Promise<ActionResult>;
  setValue(nodeID: string, text: string, options?: ActionOptions): Promise<ActionResult>;
  paste(text: string, options?: ActionOptions & { nodeID?: string; format?: 'text' | 'html'; plainText?: string }): Promise<ActionResult>;
}
export interface SafariObservationOptions extends RequestOptions {
  documentGeneration?: string; maxNodes?: number; maxDepth?: number; includeHidden?: boolean;
}
export interface SafariNode { nodeID: string; role: string; name?: string; text?: string; states?: object; frame?: Frame; children?: SafariNode[] }
export interface SafariObservation { documentGeneration: string; root?: SafariNode; truncated?: boolean; title?: string; url?: string; [key: string]: unknown }
export type SafariTarget = string | { selector: string } | { nodeID: string };
export type SafariActionResult = Omit<ActionResult, 'observation'> & { observation?: SafariObservation };
export class PabloTab {
  readonly state: SafariObservation | undefined;
  getState(options?: SafariObservationOptions): Promise<SafariObservation>;
  click(target: SafariTarget, options?: RequestOptions & { observe?: boolean }): Promise<SafariActionResult>;
  focus(target: SafariTarget, options?: RequestOptions & { observe?: boolean }): Promise<SafariActionResult>;
  setValue(target: SafariTarget, value: string, options?: RequestOptions & { observe?: boolean }): Promise<SafariActionResult>;
  scrollIntoView(target: SafariTarget, options?: RequestOptions & { observe?: boolean }): Promise<SafariActionResult>;
}
