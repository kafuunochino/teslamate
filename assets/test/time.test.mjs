import assert from "node:assert/strict";
import test from "node:test";
import { toBeijingDate, toBeijingTime } from "../js/time.mjs";

test("shows Beijing time regardless of the browser's time zone", () => {
  const previous = process.env.TZ;
  try {
    for (const zone of ["UTC", "America/Los_Angeles", "Asia/Shanghai"]) {
      process.env.TZ = zone;
      assert.equal(toBeijingTime("2026-09-09T05:50:00Z"), "13:50:00");
      assert.equal(toBeijingTime("2026-09-09T05:50:00"), "13:50:00");
      assert.equal(toBeijingTime("2026-09-09T13:50:00+08:00"), "13:50:00");
    }
  } finally {
    if (previous === undefined) delete process.env.TZ;
    else process.env.TZ = previous;
  }
});

test("uses the Beijing calendar date across midnight and year boundaries", () => {
  const options = { year: "numeric", month: "2-digit", day: "2-digit" };
  assert.equal(toBeijingDate("2026-09-09T16:00:00Z", options), "2026/09/10");
  assert.equal(toBeijingDate("2026-12-31T16:00:00Z", options), "2027/01/01");
  assert.equal(toBeijingTime("2026-09-09T16:00:00Z"), "00:00:00");
});

test("supports minute-only ranges without changing the time zone", () => {
  assert.equal(
    toBeijingTime("2026-09-09T05:50:00Z", {
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    }),
    "13:50",
  );
});

test("keeps missing or invalid timestamps empty", () => {
  for (const value of [null, undefined, "", " ", "not-a-date"]) {
    assert.equal(toBeijingTime(value), "–");
    assert.equal(toBeijingDate(value), "–");
  }
});
