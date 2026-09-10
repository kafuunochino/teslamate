import assert from "node:assert/strict";
import test from "node:test";
import { initializeTheme, THEME_STORAGE_KEY } from "../js/theme.mjs";

function browser({ dark = false, stored = null, blocked = false, legacy = false } = {}) {
  const values = new Map(stored ? [[THEME_STORAGE_KEY, stored]] : []);
  const attributes = new Map([["data-theme-mode", "light"]]);
  const media = new EventTarget();
  media.matches = dark;
  let legacyChange;
  if (legacy) {
    media.addEventListener = undefined;
    media.addListener = (listener) => {
      legacyChange = listener;
    };
  }

  const win = new EventTarget();
  win.matchMedia = () => media;
  win.CustomEvent = class extends Event {
    constructor(type, options) {
      super(type);
      this.detail = options.detail;
    }
  };
  win.localStorage = {
    getItem(key) {
      if (blocked) throw new Error("storage disabled");
      return values.get(key) ?? null;
    },
    setItem(key, value) {
      if (blocked) throw new Error("storage disabled");
      values.set(key, value);
    },
    removeItem(key) {
      if (blocked) throw new Error("storage disabled");
      values.delete(key);
    },
  };

  const classes = new Set();
  const icon = {
    classList: {
      toggle(name, enabled) {
        if (enabled) classes.add(name);
        else classes.delete(name);
      },
    },
  };
  const label = { textContent: "" };
  const buttonAttributes = new Map();
  const toggle = {
    setAttribute: (key, value) => buttonAttributes.set(key, value),
    querySelector: (selector) => (selector === "[data-theme-icon]" ? icon : label),
  };
  const system = { hidden: false };
  const select = { value: "" };
  const controls = {
    "[data-theme-toggle]": [toggle],
    "[data-theme-system]": [system],
    "[data-theme-mode-select]": [select],
  };
  const doc = new EventTarget();
  doc.documentElement = {
    setAttribute: (key, value) => attributes.set(key, value),
  };
  doc.querySelectorAll = (selector) => controls[selector] ?? [];

  return {
    win,
    doc,
    values,
    attributes,
    label,
    buttonAttributes,
    system,
    select,
    changeSystem(nextDark) {
      media.matches = nextDark;
      if (legacy) legacyChange();
      else media.dispatchEvent(new Event("change"));
    },
    click(selector) {
      const event = new Event("click");
      Object.defineProperty(event, "target", {
        value: { closest: (target) => (target === selector ? toggle : null) },
      });
      doc.dispatchEvent(event);
    },
    storage(key, value) {
      const event = new Event("storage");
      Object.assign(event, { key, newValue: value });
      win.dispatchEvent(event);
    },
  };
}

test("first visit uses the device theme before DOMContentLoaded", () => {
  for (const dark of [false, true]) {
    const b = browser({ dark });
    const theme = initializeTheme(b.win, b.doc);
    assert.equal(theme.getMode(), "system");
    assert.equal(b.attributes.get("data-theme"), dark ? "dark" : "light");
    assert.equal(b.system.hidden, true);
    assert.equal(b.values.has(THEME_STORAGE_KEY), false);
  }
});

test("topbar toggle saves an explicit choice and updates all controls", () => {
  const b = browser();
  initializeTheme(b.win, b.doc);
  b.click("[data-theme-toggle]");
  assert.equal(b.attributes.get("data-theme"), "dark");
  assert.equal(b.values.get(THEME_STORAGE_KEY), "dark");
  assert.equal(b.buttonAttributes.get("aria-pressed"), "true");
  assert.equal(b.label.textContent, "深色");
  assert.equal(b.select.value, "dark");
  assert.equal(b.system.hidden, false);
});

test("a saved choice survives reload and ignores system changes", () => {
  const b = browser({ stored: "dark" });
  const theme = initializeTheme(b.win, b.doc);
  b.changeSystem(true);
  b.changeSystem(false);
  assert.equal(theme.getTheme(), "dark");
  assert.equal(b.attributes.get("data-theme"), "dark");
});

test("following the system again clears the override and responds immediately", () => {
  const b = browser({ stored: "dark" });
  const theme = initializeTheme(b.win, b.doc);
  b.click("[data-theme-system]");
  assert.equal(theme.getMode(), "system");
  assert.equal(b.values.has(THEME_STORAGE_KEY), false);
  assert.equal(theme.getTheme(), "light");
  b.changeSystem(true);
  assert.equal(b.attributes.get("data-theme"), "dark");
});

test("storage restrictions do not stop manual switching", () => {
  const b = browser({ blocked: true });
  const theme = initializeTheme(b.win, b.doc);
  theme.setMode("dark");
  assert.equal(theme.getTheme(), "dark");
  assert.equal(b.attributes.get("data-theme"), "dark");
});

test("invalid stored values fall back to the device preference", () => {
  const b = browser({ dark: true, stored: "invalid" });
  const theme = initializeTheme(b.win, b.doc);
  assert.equal(theme.getMode(), "system");
  assert.equal(theme.getTheme(), "dark");
});

test("other tabs synchronize theme choices and storage clearing", () => {
  const b = browser();
  const theme = initializeTheme(b.win, b.doc);
  b.storage("unrelated", "dark");
  assert.equal(theme.getTheme(), "light");
  b.storage(THEME_STORAGE_KEY, "dark");
  assert.equal(theme.getTheme(), "dark");
  b.storage(null, null);
  assert.equal(theme.getMode(), "system");
  assert.equal(theme.getTheme(), "light");
});

test("bootstrap and application initialization do not register duplicate handlers", () => {
  const b = browser();
  const first = initializeTheme(b.win, b.doc);
  assert.equal(initializeTheme(b.win, b.doc), first);
  b.click("[data-theme-toggle]");
  assert.equal(first.getTheme(), "dark");
});

test("system theme changes work with legacy media-query listeners", () => {
  const b = browser({ legacy: true });
  const theme = initializeTheme(b.win, b.doc);
  b.changeSystem(true);
  assert.equal(theme.getTheme(), "dark");
});
