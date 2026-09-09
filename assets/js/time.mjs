const TIME_ZONE = "Asia/Shanghai";

function parseInstant(value) {
  if (typeof value !== "string" || value.trim() === "") return null;

  // Database timestamps without an offset represent UTC, not browser-local time.
  const input = value.trim();
  const withoutZone =
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?$/.test(input);
  const date = new Date(withoutZone ? input + "Z" : input);
  return Number.isNaN(date.valueOf()) ? null : date;
}

export function toBeijingTime(value, options = {}) {
  const date = parseInstant(value);
  return date
    ? date.toLocaleTimeString("zh-CN", {
        ...options,
        timeZone: TIME_ZONE,
        hourCycle: "h23",
      })
    : "–";
}

export function toBeijingDate(value, options = {}) {
  const date = parseInstant(value);
  return date
    ? date.toLocaleDateString("zh-CN", {
        ...options,
        timeZone: TIME_ZONE,
      })
    : "–";
}
