import test from "node:test";
import assert from "node:assert/strict";
import { mountTurnstile } from "../js/turnstile.mjs";

function fixture({ width = 340, api = true, configured = "true" } = {}) {
  const events = {};
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
        button: retry,
      })[selector],
  };
  const renders = [];
  const removed = [];
  const scripts = [];
  const doc = {
    documentElement: { dataset: { theme: "dark" } },
    querySelector: (selector) =>
      selector === "[data-turnstile]" ? root : { nonce: "page-nonce" },
    createElement: () => ({ dataset: {}, remove() {} }),
    head: { appendChild: (script) => scripts.push(script) },
  };
  const win = {
    addEventListener: (name, fn) => (events[name] = fn),
    setTimeout: (fn) => (events.timeout = fn),
    clearTimeout() {},
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
  return { win, doc, events, submit, status, retry, renders, removed, scripts };
}

test("requires a valid challenge, expires it, and blocks duplicate submissions", async () => {
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
  f.renders[0].callback();
  assert.equal(f.submit.disabled, false);
  f.events.submit({
    preventDefault() {
      assert.fail("valid token blocked");
    },
  });
  assert.equal(f.submit.disabled, true);
  f.renders[0]["expired-callback"]();
  assert.equal(f.submit.disabled, true);
  assert.equal(f.retry.hidden, false);
});

test("narrow screens use compact mode and theme changes discard previous validation", async () => {
  const f = fixture({ width: 280 });
  await mountTurnstile(f.win, f.doc).ready;
  assert.equal(f.renders[0].size, "compact");
  assert.equal(f.renders[0].theme, "dark");
  f.renders[0].callback();
  f.doc.documentElement.dataset.theme = "light";
  f.events.themechange();
  assert.deepEqual(f.removed, [1]);
  assert.equal(f.submit.disabled, true);
  assert.equal(f.renders[1].theme, "light");
  f.renders[1]["error-callback"]();
  assert.equal(f.retry.hidden, false);
  f.renders[1]["timeout-callback"]();
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
  assert.equal(f.scripts.length, 2);
  f.events.timeout();
  await retried;
  assert.equal(f.submit.disabled, true);
});

test("incomplete configuration blocks submission without loading a widget", () => {
  const f = fixture({ configured: "false" });
  assert.equal(mountTurnstile(f.win, f.doc), null);
  assert.equal(f.submit.disabled, true);
  assert.equal(f.scripts.length, 0);
});
