import test from "node:test";
import assert from "node:assert/strict";
import { mountTurnstile } from "../js/turnstile.mjs";

function fixture({ width = 340, api = true, configured = "true" } = {}) {
  const events = {};
  const timers = new Map();
  let now = 0;
  let timerId = 0;
  const submit = { disabled: false };
  const status = {};
  const host = { clientWidth: width };
  const retry = { addEventListener: (name, fn) => (events.retry = fn) };
  const form = {
    querySelector: () => submit,
    addEventListener: (name, fn) => (events.submit = fn),
  };
  const root = {
    dataset: { sitekey: "public-key", action: "register", configured },
    closest: () => form,
    querySelector: (selector) =>
      ({
        "[data-turnstile-widget]": host,
        "[data-turnstile-status]": status,
        "[data-turnstile-retry]": retry,
      })[selector],
  };
  const renders = [];
  const removed = [];
  const scripts = [];
  const doc = {
    documentElement: { dataset: { theme: "dark" } },
    querySelector: (selector) =>
      selector === "[data-turnstile]" ? root : { nonce: "page-nonce" },
    createElement: () => ({
      dataset: {},
      remove() {
        this.removed = true;
      },
    }),
    head: { appendChild: (script) => scripts.push(script) },
  };
  const win = {
    navigator: { onLine: true },
    addEventListener: (name, fn) => (events[name] = fn),
    setTimeout: (fn, delay) => {
      timers.set(++timerId, { fn, at: now + delay });
      return timerId;
    },
    clearTimeout: (id) => timers.delete(id),
    ResizeObserver: class {
      constructor(callback) {
        events.resize = callback;
      }
      observe() {}
    },
    ...(api
      ? {
          turnstile: {
            render: (_host, options) => {
              renders.push(options);
              return renders.length;
            },
            remove: (id) => removed.push(id),
          },
        }
      : {}),
  };
  async function flush() {
    await Promise.resolve();
    await Promise.resolve();
  }
  async function advance(ms) {
    const end = now + ms;
    for (;;) {
      const next = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
      if (!next || next[1].at > end) break;
      const [id, timer] = next;
      now = timer.at;
      timers.delete(id);
      timer.fn();
      await flush();
    }
    now = end;
    await flush();
  }
  return {
    win,
    doc,
    events,
    submit,
    status,
    retry,
    renders,
    removed,
    scripts,
    timers,
    host,
    flush,
    advance,
  };
}

test("requires a valid challenge and blocks duplicate submissions", async () => {
  const f = fixture();
  await mountTurnstile(f.win, f.doc).ready;
  assert.equal(f.submit.disabled, true);
  let blocked = false;
  f.events.submit({
    preventDefault() {
      blocked = true;
    },
  });
  assert.equal(blocked, true);
  f.renders[0].callback("valid-token");
  assert.equal(f.submit.disabled, false);
  f.events.submit({
    preventDefault() {
      assert.fail("valid token blocked");
    },
  });
  assert.equal(f.submit.disabled, true);
  blocked = false;
  f.events.submit({
    preventDefault() {
      blocked = true;
    },
  });
  assert.equal(blocked, true);
  assert.equal(f.timers.size, 0);
});

test("expired results are replaced and cannot authorize a later challenge", async () => {
  const f = fixture();
  await mountTurnstile(f.win, f.doc).ready;
  f.renders[0].callback("valid-token");
  assert.equal(f.submit.disabled, false);
  f.renders[0]["expired-callback"]();
  assert.equal(f.submit.disabled, true);
  await f.advance(0);
  assert.equal(f.renders.length, 2);
  f.renders[0].callback("stale-token");
  assert.equal(f.submit.disabled, true);
  f.renders[1].callback("fresh-token");
  assert.equal(f.submit.disabled, false);
});

test("narrow screens use compact mode and theme changes discard previous validation", async () => {
  const f = fixture({ width: 280 });
  await mountTurnstile(f.win, f.doc).ready;
  assert.equal(f.renders[0].size, "compact");
  assert.equal(f.renders[0].theme, "dark");
  f.renders[0].callback("valid-token");
  f.doc.documentElement.dataset.theme = "light";
  f.events.themechange();
  await f.flush();
  assert.deepEqual(f.removed, [1]);
  assert.equal(f.submit.disabled, true);
  assert.equal(f.renders[1].theme, "light");
  f.renders[1]["error-callback"]("200500");
  assert.equal(f.retry.hidden, false);
  assert.equal(f.submit.disabled, true);
  f.host.clientWidth = 340;
  f.events.resize();
  await f.flush();
  assert.equal(f.renders[2].size, "flexible");
  f.renders[1].callback("old-token");
  assert.equal(f.submit.disabled, true);
});

test("script failures stay closed and can be retried using the response CSP nonce", async () => {
  const f = fixture({ api: false });
  const controller = mountTurnstile(f.win, f.doc);
  assert.equal(f.scripts.length, 1);
  assert.equal(f.scripts[0].nonce, "page-nonce");
  assert.equal(
    f.scripts[0].src,
    "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit",
  );
  f.scripts[0].onerror();
  await controller.ready;
  assert.equal(f.submit.disabled, true);
  assert.equal(f.retry.hidden, false);
  const retried = f.events.retry();
  await f.flush();
  assert.equal(f.scripts.length, 2);
  await f.advance(45000);
  await retried;
  assert.equal(f.submit.disabled, true);
});

test("slow SDK loading gets 45 seconds, bounded retries, and a usable final error", async () => {
  const f = fixture({ api: false });
  mountTurnstile(f.win, f.doc);
  await f.advance(20000);
  assert.equal(f.scripts.length, 1);
  assert.equal(f.scripts[0].removed, undefined);
  assert.match(f.status.textContent, /连接验证服务较慢/);
  await f.advance(25000);
  assert.equal(f.scripts[0].removed, true);
  assert.match(f.status.textContent, /自动重试（1\/2）/);
  await f.advance(2000);
  assert.equal(f.scripts.length, 2);
  await f.advance(45000 + 5000 + 45000);
  assert.equal(f.scripts.length, 3);
  assert.match(f.status.textContent, /部分国内网络/);
  assert.doesNotMatch(f.status.textContent, /正在|自动重试/);
  assert.equal(f.submit.disabled, true);
  assert.equal(f.retry.hidden, false);
  assert.equal(f.timers.size, 0);
  await f.advance(300000);
  assert.equal(f.scripts.length, 3);
});

test("a widget that never calls back cannot leave the page spinning forever", async () => {
  const f = fixture();
  await mountTurnstile(f.win, f.doc).ready;
  await f.advance(60000 + 2000 + 60000 + 5000 + 60000);
  assert.equal(f.renders.length, 3);
  assert.deepEqual(f.removed, [1, 2, 3]);
  assert.equal(f.submit.disabled, true);
  assert.equal(f.retry.hidden, false);
  assert.equal(f.timers.size, 0);
  f.renders[2].callback("late-token");
  assert.equal(f.submit.disabled, true);
});

test("the SDK can finish after the previous 20 second deadline", async () => {
  const f = fixture({ api: false });
  const controller = mountTurnstile(f.win, f.doc);
  await f.advance(25000);
  let options;
  f.win.turnstile = {
    render: (_host, value) => {
      options = value;
      return 1;
    },
    remove() {},
  };
  f.scripts[0].onload();
  await controller.ready;
  options.callback("valid-token");
  assert.equal(f.submit.disabled, false);
  assert.equal(f.timers.size, 0);
  assert.equal(f.scripts.length, 1);
});

test("synchronous SDK errors discard failed widgets before a new attempt", async () => {
  const f = fixture();
  f.win.turnstile.render = (_host, options) => {
    options["error-callback"]("110200");
    return "failed-widget";
  };
  await mountTurnstile(f.win, f.doc).ready;
  assert.deepEqual(f.removed, ["failed-widget"]);
  assert.match(f.status.textContent, /域名未获/);
  assert.equal(f.submit.disabled, true);
  assert.equal(f.timers.size, 0);
});

test("transient iframe errors recover without refreshing the registration form", async () => {
  const f = fixture();
  await mountTurnstile(f.win, f.doc).ready;
  assert.equal(f.renders[0]["error-callback"]("200500"), true);
  assert.match(f.status.textContent, /200500/);
  await f.advance(2000);
  assert.equal(f.renders.length, 2);
  f.renders[1].callback("recovered-token");
  assert.equal(f.submit.disabled, false);
  assert.equal(f.timers.size, 0);
  await f.advance(180000);
  assert.equal(f.renders.length, 2);
});

test("configuration errors show their cause and never retry automatically", async () => {
  for (const [code, message] of [
    ["110100", /配置异常/],
    ["110200", /域名未获/],
    ["200100", /日期和时间/],
    ["400070", /配置异常/],
  ]) {
    const f = fixture();
    await mountTurnstile(f.win, f.doc).ready;
    f.renders[0]["error-callback"](code);
    assert.match(f.status.textContent, message);
    await f.advance(300000);
    assert.equal(f.renders.length, 1);
    assert.equal(f.submit.disabled, true);
    assert.equal(f.timers.size, 0);
  }
});

test("manual retry replaces scheduled recovery and ignores all older callbacks", async () => {
  const f = fixture();
  await mountTurnstile(f.win, f.doc).ready;
  f.renders[0]["error-callback"]("200500");
  await f.events.retry();
  f.renders[0].callback("stale-token");
  assert.equal(f.submit.disabled, true);
  f.renders[0]["error-callback"]("110200");
  assert.equal(f.status.textContent, "正在进行人机验证…");
  await f.advance(5000);
  assert.equal(f.renders.length, 2);
  f.renders[1].callback("valid-token");
  assert.equal(f.submit.disabled, false);
});

test("repeated retry while the SDK loads creates one script and one current widget", async () => {
  const f = fixture({ api: false });
  const controller = mountTurnstile(f.win, f.doc);
  const oldLoad = f.scripts[0].onload;
  const retry1 = f.events.retry();
  const retry2 = f.events.retry();
  assert.equal(f.scripts.length, 1);
  f.win.turnstile = fixture().win.turnstile;
  let rendered = 0;
  f.win.turnstile.render = () => ++rendered;
  oldLoad();
  await Promise.all([controller.ready, retry1, retry2]);
  assert.equal(rendered, 1);
});

test("offline visitors retry when connectivity returns", async () => {
  const f = fixture();
  f.win.navigator.onLine = false;
  await mountTurnstile(f.win, f.doc).ready;
  assert.equal(f.renders.length, 0);
  assert.match(f.status.textContent, /网络已断开/);
  f.win.navigator.onLine = true;
  f.events.online();
  await f.flush();
  assert.equal(f.renders.length, 1);
  f.renders[0].callback("valid-token");
  assert.equal(f.submit.disabled, false);
});

test("interactive challenges have time to finish but still have a deadline", async () => {
  const f = fixture();
  await mountTurnstile(f.win, f.doc).ready;
  f.renders[0]["before-interactive-callback"]();
  await f.advance(60000);
  assert.equal(f.renders.length, 1);
  assert.match(f.status.textContent, /请完成上方/);
  await f.advance(60000);
  assert.match(f.status.textContent, /自动重试/);
  assert.equal(f.submit.disabled, true);
});

test("an empty SDK result cannot enable submission and cached pages request a new result", async () => {
  const f = fixture();
  await mountTurnstile(f.win, f.doc).ready;
  f.renders[0].callback("");
  assert.equal(f.submit.disabled, true);
  await f.events.retry();
  f.renders[1].callback("valid-token");
  f.events.submit({ preventDefault: assert.fail });
  f.events.pageshow({ persisted: true });
  await f.flush();
  assert.equal(f.renders.length, 3);
  assert.equal(f.submit.disabled, true);
  f.renders[2].callback("fresh-token");
  assert.equal(f.submit.disabled, false);
});

test("incomplete configuration blocks submission without loading a widget", () => {
  const f = fixture({ configured: "false" });
  assert.equal(mountTurnstile(f.win, f.doc), null);
  assert.equal(f.submit.disabled, true);
  assert.equal(f.scripts.length, 0);
});
