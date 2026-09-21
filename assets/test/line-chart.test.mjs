import assert from "node:assert/strict";
import test from "node:test";
import { LineChart, nearestPoint } from "../js/line-chart.mjs";

const samples = [
  { x: 12, y: 120, time: 10, label: "2026-09-20", formatted: "61.27 kWh" },
  { x: 200, y: 70, time: 20, label: "2026-09-21", formatted: "62.45 kWh" },
  { x: 708, y: 90, time: 30, label: "2026-09-22", formatted: "61.98 kWh" },
];

function chart(points = samples) {
  const listeners = new Map();
  const nodes = Object.fromEntries(
    ["label", "value", "marker", "guide", "tooltip", "plot"].map((key) => [
      key,
      {
        style: {},
        textContent: "",
        hidden: false,
        attrs: {},
        setAttribute(key, value) {
          this.attrs[key] = value;
        },
        addEventListener(key, fn) {
          listeners.set(key, fn);
        },
        removeEventListener(key, fn) {
          if (listeners.get(key) === fn) listeners.delete(key);
        },
        getBoundingClientRect() {
          return { left: 100, width: 360 };
        },
      },
    ]),
  );
  nodes.tooltipLabel = { textContent: "" };
  nodes.tooltipValue = { textContent: "" };
  const context = {
    ...LineChart,
    el: {
      dataset: { points: JSON.stringify(points) },
      querySelector(selector) {
        if (selector === "[data-tooltip-label]") return nodes.tooltipLabel;
        if (selector === "[data-tooltip-value]") return nodes.tooltipValue;
        return nodes[selector.slice(12, -1)];
      },
    },
  };
  context.mounted();
  return {
    context,
    nodes,
    listeners,
    event(name, args = {}) {
      listeners.get(name)?.({ type: name, preventDefault() {}, ...args });
    },
  };
}

test("nearest sample uses the time-scaled x position including the chart edges", () => {
  assert.equal(nearestPoint(samples, -50), 0);
  assert.equal(nearestPoint(samples, 300), 1);
  assert.equal(nearestPoint(samples, 1000), 2);
});

test("hover and touch show the exact sample with date and units", () => {
  const c = chart();
  assert.equal(c.nodes.value.textContent, "61.98 kWh");
  c.event("pointermove", { clientX: 200, pointerType: "mouse" });
  assert.equal(c.nodes.value.textContent, "62.45 kWh");
  assert.equal(c.nodes.tooltipLabel.textContent, "2026-09-21");
  assert.equal(c.nodes.tooltip.hidden, false);
  c.event("pointerdown", { clientX: 106, pointerType: "touch" });
  assert.equal(c.nodes.value.textContent, "61.27 kWh");
  assert.equal(c.nodes.guide.attrs.x1, 12);
  c.event("pointerleave");
  assert.equal(c.nodes.tooltip.hidden, true);
  assert.equal(c.nodes.value.textContent, "61.27 kWh");
});

test("keyboard navigation clamps at first and last samples", () => {
  const c = chart();
  c.event("keydown", { key: "Home" });
  c.event("keydown", { key: "ArrowLeft" });
  assert.equal(c.nodes.value.textContent, "61.27 kWh");
  c.event("keydown", { key: "ArrowRight" });
  assert.equal(c.nodes.value.textContent, "62.45 kWh");
  c.event("keydown", { key: "End" });
  c.event("keydown", { key: "ArrowRight" });
  assert.equal(c.nodes.value.textContent, "61.98 kWh");
});

test("LiveView refresh preserves an inspected sample and removes old listeners", () => {
  const c = chart();
  c.event("keydown", { key: "Home" });
  c.context.el.dataset.points = JSON.stringify([
    ...samples,
    { ...samples[2], time: 40, formatted: "63.01 kWh" },
  ]);
  c.context.updated();
  assert.equal(c.nodes.value.textContent, "61.27 kWh");
  assert.equal(c.listeners.size, 6);
  c.context.destroyed();
  assert.equal(c.listeners.size, 0);
});

test("latest selection follows new samples and recovers after empty data", () => {
  const c = chart();
  c.context.el.dataset.points = JSON.stringify([
    ...samples,
    { ...samples[2], time: 40, formatted: "63.01 kWh" },
  ]);
  c.context.updated();
  assert.equal(c.nodes.value.textContent, "63.01 kWh");
  c.context.el.dataset.points = "[]";
  c.context.updated();
  assert.equal(c.listeners.size, 0);
  c.context.el.dataset.points = JSON.stringify(samples);
  c.context.updated();
  assert.equal(c.nodes.value.textContent, "61.98 kWh");
});
