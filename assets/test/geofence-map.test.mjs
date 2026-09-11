import assert from "node:assert/strict";
import test from "node:test";
import {
  fromGCJ02, parseGeoFence, createAMapGeoFenceAdapter,
  createLeafletGeoFenceAdapter, createGeoFenceMapHook,
} from "../js/geofence-map.mjs";
import { toGCJ02 } from "../js/vehicle-map.mjs";

test("geofence edits round-trip mainland display coordinates and preserve overseas coordinates", () => {
  for (const source of [
    { latitude: 39.915, longitude: 116.404 },
    { latitude: 26.647, longitude: 106.63 },
    { latitude: 31.23, longitude: 121.47 },
    { latitude: 22.54, longitude: 114.06 },
    { latitude: 48.8566, longitude: 2.3522 },
    { latitude: -25.066188, longitude: -130.100502 },
    { latitude: 0, longitude: 0 },
  ]) {
    const original = { ...source };
    const [longitude, latitude] = toGCJ02(source);
    const saved = fromGCJ02({ latitude, longitude });
    assert.ok(Math.abs(saved.latitude - source.latitude) < 1e-8);
    assert.ok(Math.abs(saved.longitude - source.longitude) < 1e-8);
    assert.deepEqual(source, original);
  }
});

test("invalid form values never become a circle at zero or an invalid radius", () => {
  const value = { latitude: "0", longitude: "0", radius: "20" };
  assert.deepEqual(parseGeoFence(value), { latitude: 0, longitude: 0, radius: 20 });
  for (const patch of [
    { latitude: "" }, { longitude: null }, { longitude: true },
    { latitude: 91 }, { longitude: 181 }, { latitude: "wat" },
    { radius: 0 }, { radius: 5000 }, { radius: 3.2 }, { radius: Infinity },
  ]) assert.equal(parseGeoFence({ ...value, ...patch }), null);
});

function amap() {
  const calls = { maps: [], circles: [], editors: [] };
  const point = ([lng, lat]) => ({ getLng: () => lng, getLat: () => lat });
  class Map {
    constructor(canvas, options) { this.options = options; this.events = {}; calls.maps.push(this); }
    on(name, callback) { this.events[name] = callback; }
    add() {}
    setFitView() {}
    resize() { this.resized = true; }
    destroy() { this.destroyed = true; }
  }
  class Circle {
    constructor(options) { this.center = options.center; this.radius = options.radius; calls.circles.push(this); }
    setCenter(value) { this.center = value; }
    getCenter() { return point(this.center); }
    setRadius(value) { this.radius = value; }
    getRadius() { return this.radius; }
  }
  class CircleEditor {
    constructor() { this.events = {}; calls.editors.push(this); }
    on(name, callback) { this.events[name] = callback; }
    open() { this.opened = true; this.events.adjust?.(); }
    close() { this.opened = false; }
  }
  class Geocoder {
    getLocation(query, callback) {
      calls.query = query;
      callback("complete", { geocodes: [{
        formattedAddress: "测试地点",
        location: point(toGCJ02({ latitude: 26.647, longitude: 106.63 })),
      }] });
    }
  }
  return { sdk: { Map, Circle, CircleEditor, Geocoder }, calls, point };
}

test("AMap opens without mutating stored WGS84, keeps centers exact on resize and converts dragged centers", () => {
  const { sdk, calls, point } = amap();
  const adapter = createAMapGeoFenceAdapter(sdk, {}, { ready() {}, failed() {} });
  const source = { latitude: 26.647123, longitude: 106.630456, radius: 100 };
  const changes = [];
  adapter.onChange((value) => changes.push(value));
  adapter.render(source);
  assert.equal(changes.length, 0);
  assert.deepEqual(calls.circles[0].center, toGCJ02(source));
  calls.circles[0].radius = 150;
  calls.editors[0].events.adjust();
  assert.deepEqual(changes[0], { ...source, radius: 150 });
  const moved = { latitude: 26.650123, longitude: 106.640456 };
  calls.circles[0].center = toGCJ02(moved);
  calls.editors[0].events.move();
  assert.ok(Math.abs(changes[1].latitude - moved.latitude) < 1e-8);
  assert.ok(Math.abs(changes[1].longitude - moved.longitude) < 1e-8);
  calls.circles[0].radius = 6000;
  calls.editors[0].events.adjust();
  assert.equal(changes.at(-1).radius, 4999);
  calls.maps[0].events.click({ lnglat: point(toGCJ02(source)) });
  assert.ok(Math.abs(changes.at(-1).latitude - source.latitude) < 1e-8);
  assert.equal(calls.maps[0].options.mapStyle, "amap://styles/normal");
  adapter.resize();
  adapter.destroy();
  const count = changes.length;
  calls.editors[0].events.move();
  assert.equal(changes.length, count);
  assert.ok(calls.maps[0].resized && calls.maps[0].destroyed);
  assert.equal(calls.editors[0].opened, false);
});

test("AMap address results convert back to the same canonical coordinates as map edits", async () => {
  const { sdk, calls } = amap();
  const adapter = createAMapGeoFenceAdapter(sdk, {}, { ready() {}, failed() {} });
  const [result] = await adapter.search("贵阳市测试地址");
  assert.equal(calls.query, "贵阳市测试地址");
  assert.equal(result.label, "测试地点");
  assert.ok(Math.abs(result.latitude - 26.647) < 1e-8);
  assert.ok(Math.abs(result.longitude - 106.63) < 1e-8);
  adapter.destroy();
});

test("OpenStreetMap edits keep WGS84 and follow light/dark themes with cleanup", async () => {
  let map, circle;
  class Map {
    constructor() { map = this; this.events = {}; }
    on(name, fn) { this.events[name] = fn; }
    fitBounds() {}
    invalidateSize() {}
    remove() { this.removed = true; }
  }
  class TileLayer {
    on() {}
    addTo() {}
  }
  class Circle {
    constructor(center, options) {
      circle = this; this.center = center; this.radius = options.radius; this.events = {};
      this.pm = { enable: () => {}, disable: () => {} };
    }
    addTo() { return this; }
    on(name, fn) { this.events[name] = fn; }
    setLatLng(center) { this.center = center; }
    getLatLng() { return { lat: this.center[0], lng: this.center[1] }; }
    setRadius(radius) { this.radius = radius; }
    getRadius() { return this.radius; }
    getBounds() { return {}; }
  }
  const themes = [];
  const canvas = { classList: { toggle: (name, value) => themes.push([name, value]) } };
  const adapter = createLeafletGeoFenceAdapter(
    { Map, TileLayer, Circle },
    { geocode: async () => [{ name: "Paris", center: { lat: 48.85, lng: 2.35 } }] },
    canvas,
    { theme: "dark", ready() {}, failed() {} },
  );
  const changes = [];
  adapter.onChange((value) => changes.push(value));
  const value = { latitude: 26.647, longitude: 106.63, radius: 20 };
  adapter.render(value);
  assert.deepEqual(circle.center, [26.647, 106.63]);
  assert.equal(changes.length, 0);
  circle.radius = 45;
  circle.events["pm:edit"]();
  assert.deepEqual(changes[0], { ...value, radius: 45 });
  map.events.click({ latlng: { lat: 27, lng: 107 } });
  assert.deepEqual(changes[1], { latitude: 27, longitude: 107, radius: 45 });
  assert.deepEqual(await adapter.search("Paris"), [{ label: "Paris", latitude: 48.85, longitude: 2.35 }]);
  adapter.setTheme("light");
  assert.deepEqual(themes.map((entry) => entry[1]), [true, false]);
  adapter.destroy();
  assert.ok(map.removed);
});

function environment() {
  class Element extends EventTarget {
    constructor() {
      super();
      this.dataset = {};
      this.classList = { add() {} };
      this.children = [];
      this.value = "";
    }
    setAttribute() {}
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this.children = children; }
  }
  const fields = Object.fromEntries(["latitude", "longitude", "radius"].map((name) => [name, new Element()]));
  Object.assign(fields.latitude, { value: "26.647123" });
  Object.assign(fields.longitude, { value: "106.630456" });
  Object.assign(fields.radius, { value: "20" });
  const search = Object.fromEntries(["query", "search", "results", "search-status"].map((name) => [name, new Element()]));
  const form = { querySelector(selector) {
    for (const [name, field] of Object.entries(fields))
      if (selector === '[name="geo_fence[' + name + ']"]') return field;
    return search[selector.replace("[data-geofence-", "").replace("]", "")];
  } };
  const el = new Element();
  el.closest = () => form;
  const win = new EventTarget();
  win.Event = Event;
  win.setTimeout = () => 1;
  win.clearTimeout = () => {};
  win.location = { reload() {} };
  const doc = { createElement: () => new Element(), documentElement: { dataset: { theme: "dark" } } };
  return { win, doc, el, fields, search };
}

function adapterMock() {
  return {
    values: [],
    render(value) { this.values.push(value); },
    onChange(listener) { this.change = listener; },
    search: async () => [],
    destroy() { this.destroyed = true; },
  };
}

test("saved AMap configuration selects the geofence adapter and latest form data after loading", async () => {
  const e = environment();
  const adapter = adapterMock();
  let resolveSDK, configurations = 0, options;
  const pending = new Promise((resolve) => { resolveSDK = resolve; });
  const hook = createGeoFenceMapHook(() => assert.fail("foreign fallback"), {
    window: e.win, document: e.doc,
    fetchConfig: async () => { configurations++; return { provider: "amap" }; },
    loadSDK: () => pending,
    createAMap: (_sdk, _canvas, opts) => { options = opts; return adapter; },
  });
  hook.el = e.el;
  hook.mounted();
  e.fields.radius.value = "120";
  hook.updated();
  resolveSDK({ CircleEditor: true, Geocoder: true });
  await hook.loading;
  options.ready();
  assert.equal(configurations, 1);
  assert.equal(hook.canvas.dataset.mapProvider, "amap");
  assert.deepEqual(adapter.values, [{ latitude: 26.647123, longitude: 106.630456, radius: 120 }]);
  assert.equal(hook.status.hidden, true);
  assert.equal(e.search.search.disabled, false);
  hook.destroyed();
});

test("circle edits send one form input event with both coordinates and radius without duplicate renders", async () => {
  const e = environment();
  const adapter = adapterMock();
  const hook = createGeoFenceMapHook(() => adapter, {
    window: e.win, document: e.doc,
    fetchConfig: async () => ({ provider: "openstreetmap" }),
  });
  hook.el = e.el;
  let events = 0;
  e.fields.radius.addEventListener("input", (event) => {
    events++;
    assert.ok(event.bubbles);
    assert.equal(Number(e.fields.latitude.value), 27);
    assert.equal(Number(e.fields.longitude.value), 107);
  });
  hook.mounted();
  await hook.loading;
  adapter.change({ latitude: 27, longitude: 107, radius: 60 });
  assert.equal(events, 1);
  assert.equal(adapter.values.length, 1);
  hook.updated();
  assert.equal(adapter.values.length, 1);
  hook.destroyed();
});

test("search does not change the fence until a result is selected and preserves the radius", async () => {
  const e = environment();
  const adapter = adapterMock();
  adapter.search = async () => [{ label: "Test location", latitude: 28, longitude: 108 }];
  const hook = createGeoFenceMapHook(() => adapter, {
    window: e.win, document: e.doc,
    fetchConfig: async () => ({ provider: "openstreetmap" }),
  });
  hook.el = e.el;
  hook.mounted();
  await hook.loading;
  e.search.query.value = "Test";
  await hook.search();
  assert.equal(Number(e.fields.latitude.value), 26.647123);
  assert.equal(e.search.results.children.length, 1);
  e.search.results.children[0].onclick();
  assert.equal(Number(e.fields.latitude.value), 28);
  assert.equal(Number(e.fields.longitude.value), 108);
  assert.equal(Number(e.fields.radius.value), 20);
  assert.match(e.search["search-status"].textContent, /保存后生效/);
  hook.destroyed();
});

test("provider errors never silently switch the geofence to OpenStreetMap", async () => {
  const e = environment();
  const hook = createGeoFenceMapHook(() => assert.fail("foreign fallback"), {
    window: e.win, document: e.doc,
    fetchConfig: async () => ({ provider: "amap" }),
    loadSDK: async () => { throw new Error("高德地图加载失败"); },
  });
  hook.el = e.el;
  hook.mounted();
  await hook.loading;
  assert.equal(hook.statusText.textContent, "高德地图加载失败");
  assert.equal(hook.reload.hidden, false);
  assert.equal(e.search.search.disabled, true);
  hook.destroyed();
});

test("late SDK completion and address results are ignored after leaving the form", async () => {
  const e = environment();
  let resolve;
  const pending = new Promise((r) => { resolve = r; });
  const hook = createGeoFenceMapHook(() => assert.fail("late map"), {
    window: e.win, document: e.doc,
    fetchConfig: () => pending,
  });
  hook.el = e.el;
  hook.mounted();
  hook.destroyed();
  resolve({ provider: "openstreetmap" });
  await hook.loading;
  assert.equal(hook.adapter, undefined);

  const second = environment();
  const adapter = adapterMock();
  let complete;
  adapter.search = () => new Promise((r) => { complete = r; });
  const searching = createGeoFenceMapHook(() => adapter, {
    window: second.win, document: second.doc,
    fetchConfig: async () => ({ provider: "openstreetmap" }),
  });
  searching.el = second.el;
  searching.mounted();
  await searching.loading;
  second.search.query.value = "Test";
  const result = searching.search();
  searching.destroyed();
  complete([{ label: "Late", latitude: 1, longitude: 2 }]);
  await result;
  assert.equal(second.search.results.children.length, 0);
  assert.equal(Number(second.fields.latitude.value), 26.647123);
});
