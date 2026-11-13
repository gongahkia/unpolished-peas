import {chromium, firefox} from "playwright";
import {writeFile} from "node:fs/promises";
import {WebDriver} from "../safari_webdriver.mjs";

const elementKey = "element-6066-11e4-a52e-4f735466cecf";
const keys = {Enter: "\ue007", ArrowLeft: "\ue012", ArrowRight: "\ue014", ArrowDown: "\ue015", ArrowUp: "\ue013", Escape: "\ue00c", F4: "\ue034", F5: "\ue035", Space: "\ue00d"};
export const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

class Adapter {
  closed = false;
  assertOpen() { if (this.closed) throw new Error("browser adapter is closed"); }
  async wait(fn, argument, label = "workflow state", timeoutMs = 15000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (await this.evaluate(fn, argument)) return;
      await sleep(50);
    }
    throw new Error(`timed out waiting for ${label}`);
  }
  async press(key) { await this.down(key); await sleep(40); await this.up(key); }
  async evaluateInput(fn, argument) { return this.evaluate(fn, argument); }
  async reload() { await this.navigate(this.url); }
}

export class PlaywrightAdapter extends Adapter {
  constructor(name) { super(); this.name = name; }
  async open() {
    const implementation = this.name === "firefox" ? firefox : chromium;
    this.browser = await implementation.launch({headless: true, ...(this.name === "chromium" ? {channel: "chrome"} : {}), timeout: 20000});
    this.context = await this.browser.newContext({viewport: {width: 1100, height: 760}});
    this.page = await this.context.newPage();
    this.page.setDefaultTimeout(15000);
    this.page.setDefaultNavigationTimeout(20000);
    this.console = [];
    this.page.on("console", (message) => this.console.push({type: message.type(), text: message.text()}));
    this.page.on("pageerror", (error) => this.console.push({type: "pageerror", text: error.stack}));
    this.version = this.browser.version();
  }
  async navigate(url) { this.assertOpen(); this.url = url; await this.page.goto(url); }
  async reload() { this.assertOpen(); await this.page.reload(); }
  async evaluate(fn, argument) { this.assertOpen(); return this.page.evaluate(fn, argument); }
  async down(key) { this.assertOpen(); await this.page.keyboard.down(key); }
  async up(key) { this.assertOpen(); await this.page.keyboard.up(key); }
  async click(selector) { this.assertOpen(); await this.page.locator(selector).click(); }
  async text(value) { this.assertOpen(); await this.page.keyboard.insertText(value); }
  async screenshot(path) { this.assertOpen(); await this.page.screenshot({path}); }
  async close() { this.closed = true; await this.browser?.close(); }
}

export class SafariAdapter extends Adapter {
  name = "safari";
  constructor(url = process.env.UP_SAFARI_WEBDRIVER_URL ?? "http://127.0.0.1:4444") { super(); this.client = new WebDriver(url); }
  async open() {
    const status = await this.client.status();
    if (status.ready === false) throw new Error("Safari WebDriver already has an active session");
    await this.client.createSession();
    this.version = this.client.capabilities.browserVersion;
    await this.client.request(this.client.path("/timeouts"), "POST", {script: 15000, pageLoad: 20000, implicit: 0});
  }
  async navigate(url) { this.assertOpen(); this.url = url; await this.client.navigate(url); }
  async reload() { this.assertOpen(); await this.client.request(this.client.path("/refresh"), "POST", {}); }
  async evaluate(fn, argument) {
    this.assertOpen();
    const script = `const done = arguments[arguments.length - 1]; Promise.resolve().then(() => (${fn.toString()})(arguments[0])).then(value => done({ok:true,value:value ?? null}), error => done({ok:false,message:error.stack ?? String(error)}));`;
    const result = await this.client.request(this.client.path("/execute/async"), "POST", {script, args: [argument ?? null]});
    if (!result?.ok) throw new Error(result?.message ?? "Safari returned no script result");
    return result.value;
  }
  async ensureWindowFocus() {
    if (!this.url) return;
    if (await this.evaluate(() => document.hasFocus())) return;
    // Safari can deliver trusted key events to a background automation window.
    // Raise the actual WebDriver window; never inject DOM focus/key events.
    const handle = await this.client.request(this.client.path("/window"));
    await this.client.request(this.client.path("/window"), "POST", {handle});
    await this.wait(() => document.hasFocus(), null, "Safari automation window focus");
  }
  async key(type, key) {
    this.assertOpen();
    if (type === "keyDown") await this.ensureWindowFocus();
    await this.client.actions([{type: "key", id: "keyboard", actions: [{type, value: keys[key] ?? key}]}]);
  }
  async evaluateInput(fn, argument) {
    // Injected composition is still an input action and needs the same real
    // window focus as trusted keys/text; observations must not change focus.
    await this.ensureWindowFocus();
    return this.evaluate(fn, argument);
  }
  async down(key) { await this.key("keyDown", key); }
  // Release the source through WebDriver's input-state cancellation endpoint.
  // Safari can omit ordinary-character keyup for separate keyUp action calls.
  // Shared workflows hold one key at a time; this sends genuine release events.
  async up(_key) { this.assertOpen(); await this.client.releaseActions(); }
  async click(selector) { this.assertOpen(); await this.ensureWindowFocus(); await this.client.click(await this.client.find(selector)); }
  async text(value) {
    this.assertOpen();
    await this.ensureWindowFocus();
    const id = await this.client.find("textarea[aria-label='Game text input']");
    await this.client.request(this.client.path(`/element/${id}/value`), "POST", {text: value, value: Array.from(value)});
  }
  async screenshot(path) { this.assertOpen(); await writeFile(path, Buffer.from(await this.client.screenshot(), "base64")); }
  async close() {
    this.closed = true;
    if (this.client.sessionId) {
      try { await this.client.releaseActions(); } finally { await this.client.deleteSession(); }
    }
  }
}

export function adapter(name) {
  if (name === "safari") return new SafariAdapter();
  if (name === "chromium" || name === "firefox") return new PlaywrightAdapter(name);
  throw new Error(`unknown authoring browser: ${name}`);
}

export function prerequisiteFailure(error) {
  return /Allow remote automation|enable.*automation|Executable doesn't exist|browser.*not found|ECONNREFUSED|fetch failed|Host system is missing dependencies|already.*active session/i.test(error.message);
}
