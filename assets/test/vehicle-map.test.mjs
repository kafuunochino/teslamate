import assert from "node:assert/strict";
import test from "node:test";
import {
  parseMapPoints,
  toGCJ02,
  createAMapAdapter,
  createVehicleMapHook,
} from "../js/vehicle-map.mjs";

test("rejects missing, malformed and out-of-range positions without placing a car at zero", () => {
  for (const value of [
    "oops",
    "null",
    "{}",
    '[{"latitude":null,"longitude":30}]',
    '[{"latitude":"","longitude":30}]',
    '[{"latitude":true,"longitude":30}]',
    '[{"latitude":91,"longitude":30}]',
    '[{"latitude":30,"longitude":181}]',
  ]) {
    assert.deepEqual(parseMapPoints(value), []);
  }
  assert.deepEqual(
    parseMapPoints(
      '[{"latitude":"0","longitude":"0"},{"latitude":"39.9","longitude":"116.3"}]',
    ),
    [
      { latitude: 0, longitude: 0 },
      { latitude: 39.9, longitude: 116.3 },
    ],
  );
});

test("matches the existing mainland coordinate conversion and leaves source data unchanged", () => {
  const point = { latitude: 39.915, longitude: 116.404 };
  const converted = toGCJ02(point);
  assert.ok(Math.abs(converted[0] - 116.41024449916938) < 1e-9);
  assert.ok(Math.abs(converted[1] - 39.91640428150164) < 1e-9);
  assert.deepEqual(point, { latitude: 39.915, longitude: 116.404 });
  assert.deepEqual(
    toGCJ02({ latitude: 48.8566, longitude: 2.3522 }),
    [2.3522, 48.8566],
  );
});

function amap() {
  const calls = { markers: [], maps: [] };
  class Map {
    constructor(_canvas, options) {
      this.options = options;
      this.events = {};
      calls.maps.push(this);
    }
    on(name, callback) {
      this.events[name] = callback;
    }
    add() {}
    setZoomAndCenter(zoom, point) {
      this.zoom = zoom;
      this.center = point;
    }
    getBounds() {
      return { contains: () => false };
    }
    setCenter(point) {
      this.center = point;
    }
    setMapStyle(style) {
      this.style = style;
    }
    resize() {
      this.resized = true;
    }
    destroy() {
      this.destroyed = true;
    }
  }
  class Marker {
    constructor(options) {
      this.position = options.position;
      calls.markers.push(this);
    }
    setPosition(position) {
      this.position = position;
    }
  }
  return { sdk: { Map, Marker }, calls };
}

test("uses native dark styles and moves the current marker without recreating the map", () => {
  const { sdk, calls } = amap();
  const adapter = createAMapAdapter(
    sdk,
    {},
    { theme: "dark", ready() {}, failed() {} },
  );
  const first = { latitude: 39.915, longitude: 116.404 };
  const next = { latitude: 39.916, longitude: 116.405 };
  adapter.render([first]);
  adapter.render([next]);
  assert.equal(calls.maps.length, 1);
  assert.equal(calls.markers.length, 1);
  assert.deepEqual(calls.markers[0].position, toGCJ02(next));
  assert.equal(calls.maps[0].options.mapStyle, "amap://styles/dark");
  adapter.setTheme("light");
  assert.equal(calls.maps[0].style, "amap://styles/normal");
  adapter.resize();
  adapter.destroy();
  assert.ok(calls.maps[0].resized);
  assert.ok(calls.maps[0].destroyed);
});

function environment() {
  const element = () => ({
    dataset: {},
    classList: { add() {} },
    setAttribute() {},
    append() {},
    replaceChildren() {},
  });
  const win = new EventTarget();
  win.setTimeout = () => 1;
  win.clearTimeout = () => {};
  win.location = { reload() {} };
  const doc = {
    createElement: element,
    documentElement: { dataset: { theme: "dark" } },
  };
  return { win, doc, element };
}

test("reads the newest position after asynchronous map startup and follows theme changes", async () => {
  const { win, doc, element } = environment();
  let resolve;
  const pending = new Promise((r) => {
    resolve = r;
  });
  const points = [],
    themes = [];
  let destroyed = false;
  const hook = createVehicleMapHook(
    (_canvas, options) => {
      assert.equal(options.theme, "dark");
      return {
        render(value) {
          points.push(value);
        },
        setTheme(value) {
          themes.push(value);
        },
        destroy() {
          destroyed = true;
        },
      };
    },
    { window: win, document: doc, fetchConfig: () => pending },
  );
  hook.el = element();
  hook.el.dataset.points = '[{"latitude":30,"longitude":110}]';
  hook.mounted();
  hook.el.dataset.points = '[{"latitude":31,"longitude":111}]';
  hook.updated();
  resolve({ provider: "openstreetmap" });
  await hook.loading;
  assert.deepEqual(points, [[{ latitude: 31, longitude: 111 }]]);
  doc.documentElement.dataset.theme = "light";
  win.dispatchEvent(new Event("themechange"));
  assert.deepEqual(themes, ["light"]);
  hook.destroyed();
  win.dispatchEvent(new Event("themechange"));
  assert.equal(themes.length, 1);
  assert.ok(destroyed);
});

test("does not create a map after navigating away while the SDK is loading", async () => {
  const { win, doc, element } = environment();
  let resolve;
  const pending = new Promise((r) => {
    resolve = r;
  });
  const { sdk, calls } = amap();
  const hook = createVehicleMapHook(() => assert.fail("unexpected fallback"), {
    window: win,
    document: doc,
    fetchConfig: async () => ({ provider: "amap" }),
    loadSDK: () => pending,
  });
  hook.el = element();
  hook.el.dataset.points = '[{"latitude":30,"longitude":110}]';
  hook.mounted();
  await Promise.resolve();
  hook.destroyed();
  resolve(sdk);
  await hook.loading;
  assert.equal(calls.maps.length, 0);
});

test("shows a recoverable error instead of silently falling back to a foreign provider", async () => {
  const { win, doc, element } = environment();
  const hook = createVehicleMapHook(() => assert.fail("unexpected fallback"), {
    window: win,
    document: doc,
    fetchConfig: async () => ({ provider: "amap" }),
    loadSDK: async () => {
      throw new Error("高德地图加载失败");
    },
  });
  hook.el = element();
  hook.mounted();
  await hook.loading;
  assert.equal(hook.statusText.textContent, "高德地图加载失败");
  assert.equal(hook.reload.hidden, false);
  hook.destroyed();
});
