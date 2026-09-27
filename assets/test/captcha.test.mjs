import test from "node:test";
import assert from "node:assert/strict";
import { mountCaptcha } from "../js/captcha.mjs";

function fixture(provider, { api = true } = {}) {
  const events = {},
    timers = new Map(),
    scripts = [],
    renders = [];
  let timerId = 0;
  const submit = {},
    status = {},
    token = {},
    randstr = {};
  const retry = { addEventListener: (_name, fn) => (events.retry = fn) };
  const button = () => ({
    disabled: true,
    cloneNode: button,
    replaceWith(next) {
      elements["[data-captcha-trigger]"] = next;
    },
    addEventListener: (_name, fn) => (events.trigger = fn),
  });
  const elements = {
    "[data-captcha-status]": status,
    "[data-captcha-retry]": retry,
    "[data-captcha-token]": token,
    "[data-captcha-randstr]": randstr,
    "[data-captcha-trigger]": button(),
  };
  const form = {
    querySelector: () => submit,
    addEventListener: (_name, fn) => (events.submit = fn),
  };
  const root = {
    dataset: {
      provider,
      configured: "true",
      region: "cn",
      prefix: "identity",
      scene: "scene-id",
      appId: "123456",
    },
    closest: () => form,
    querySelector: (s) => elements[s],
  };
  const doc = {
    querySelector: (s) =>
      s === "[data-captcha]" ? root : { nonce: "fresh-nonce" },
    createElement: () => ({
      dataset: {},
      remove() {
        this.removed = true;
      },
    }),
    head: { appendChild: (s) => scripts.push(s) },
  };
  const win = {
    navigator: { onLine: true },
    innerWidth: 320,
    addEventListener: (name, fn) => (events[name] = fn),
    setTimeout: (fn, ms) => {
      timers.set(++timerId, { fn, ms });
      return timerId;
    },
    clearTimeout: (id) => timers.delete(id),
  };
  const install = () => {
    win.TencentCaptcha = class {
      constructor(appid, callback) {
        renders.push({ appid, callback });
      }
      show() {}
      destroy() {}
    };
    win.initAliyunCaptcha = (options) => {
      renders.push(options);
      options.getInstance({ hide() {} });
    };
  };
  if (api) install();
  const flush = async () => {
    await Promise.resolve();
    await Promise.resolve();
  };
  const expire = async (ms) => {
    for (const [id, t] of [...timers])
      if (t.ms === ms) {
        timers.delete(id);
        t.fn();
      }
    await flush();
  };
  const accept = (index = renders.length - 1, value = "valid-ticket") =>
    provider === "tencent"
      ? renders[index].callback({ ret: 0, ticket: value, randstr: "random" })
      : renders[index].success(value);
  return {
    win,
    doc,
    elements,
    events,
    timers,
    scripts,
    renders,
    submit,
    status,
    token,
    randstr,
    retry,
    install,
    flush,
    expire,
    accept,
  };
}

for (const provider of ["aliyun", "tencent"]) {
  test(`${provider}: proof gates submit, expires, and rejects stale callbacks`, async () => {
    const f = fixture(provider);
    await mountCaptcha(f.win, f.doc).ready;
    let blocked = false;
    f.events.submit({ preventDefault: () => (blocked = true) });
    assert.equal(blocked, true);
    f.accept();
    assert.equal(f.submit.disabled, false);
    assert.equal(f.token.value, "valid-ticket");
    await f.expire(provider === "aliyun" ? 75000 : 240000);
    assert.equal(f.token.value, "");
    assert.equal(f.submit.disabled, true);
    await f.events.retry();
    f.accept(0, "stale");
    assert.equal(f.token.value, "");
    f.accept();
    f.events.submit({
      preventDefault: () => assert.fail("valid proof blocked"),
    });
    blocked = false;
    f.events.submit({ preventDefault: () => (blocked = true) });
    assert.equal(blocked, true);
    assert.equal(f.timers.size, 0);
  });

  test(`${provider}: SDK timeout stops loading and allows a clean retry`, async () => {
    const f = fixture(provider, { api: false });
    const pending = mountCaptcha(f.win, f.doc);
    assert.equal(f.scripts[0].nonce, "fresh-nonce");
    await f.expire(20000);
    await pending.ready;
    assert.equal(f.retry.hidden, false);
    assert.equal(f.submit.disabled, true);
    assert.equal(f.scripts[0].removed, true);
    const retry = f.events.retry();
    assert.equal(f.scripts.length, 2);
    f.install();
    f.scripts[1].onload();
    await retry;
    f.accept();
    assert.equal(f.submit.disabled, false);
  });

  test(`${provider}: BFCache restoration and offline events discard proof`, async () => {
    const f = fixture(provider);
    await mountCaptcha(f.win, f.doc).ready;
    f.accept();
    f.events.pageshow({ persisted: true });
    await f.flush();
    assert.equal(f.token.value, "");
    f.accept();
    f.events.offline();
    assert.equal(f.token.value, "");
    assert.equal(f.submit.disabled, true);
  });
}

test("Tencent disaster recovery tickets never enable submit", async () => {
  const f = fixture("tencent");
  await mountCaptcha(f.win, f.doc).ready;
  f.accept(0, "trerror_fake-ticket");
  assert.equal(f.submit.disabled, true);
  assert.equal(f.token.value, "");
});

test("Alibaba sets region/prefix before loading and scales the popup for mobile", async () => {
  const f = fixture("aliyun", { api: false });
  const pending = mountCaptcha(f.win, f.doc);
  assert.deepEqual(f.win.AliyunCaptchaConfig, {
    region: "cn",
    prefix: "identity",
  });
  f.install();
  f.scripts[0].onload();
  await pending.ready;
  assert.equal(f.renders[0].SceneId, "scene-id");
  assert.equal(f.renders[0].rem, 0.9);
});
