import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dashboardRoot = path.join(projectRoot, "grafana", "dashboards");

const importedFiles = new Set([
  "amortization.json",
  "annual-summary.json",
  "charging-costs-stats.json",
  "charging-curve-stats.json",
  "charging-health.json",
  "continuous-trips.json",
  "cost-savings.json",
  "current-charge.json",
  "current-drive.json",
  "current-state.json",
  "dc-charging-curves-carrier.json",
  "driving-patterns.json",
  "driving-score.json",
  "incomplete-data.json",
  "mileage-stats.json",
  "range-degradation.json",
  "regen-braking.json",
  "sentry-drain.json",
  "speed-rates.json",
  "speed-temperature.json",
  "station-ranking.json",
  "tire-pressure.json",
  "tracking-drives.json",
  "vehicle-comparison.json",
  "weather-efficiency.json",
]);

const officialMapFiles = new Set([
  "charging-stats.json",
  "trip.json",
  "visited.json",
  "internal/charge-details.json",
  "internal/drive-details.json",
]);

const amapUrl =
  "https://wprd01.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=7&x={x}&y={y}&z={z}";
const allowedMapUrls = new Set([
  amapUrl,
  "https://webst01.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}",
  "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
]);

const allowedPanelTypes = new Set([
  "barchart",
  "bargauge",
  "gauge",
  "geomap",
  "heatmap",
  "piechart",
  "row",
  "state-timeline",
  "stat",
  "table",
  "text",
  "timeseries",
  "trend",
  "xychart",
]);

const writeSql = /\b(insert|update|delete|drop|alter|truncate|grant|revoke|copy|call|do)\b/i;
const privateIp = /https?:\/\/(?:10\.|127\.|169\.254\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)/i;
const errors = [];
const seenUids = new Map();

function visit(node, callback, location = "root") {
  callback(node, location);
  if (Array.isArray(node)) {
    node.forEach((value, index) => visit(value, callback, `${location}[${index}]`));
  } else if (node && typeof node === "object") {
    Object.entries(node).forEach(([key, value]) => visit(value, callback, `${location}.${key}`));
  }
}

function dashboardFiles(directory, prefix = "") {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const relativePath = path.join(prefix, entry.name);
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return dashboardFiles(fullPath, relativePath);
    return entry.name.endsWith(".json") ? [relativePath] : [];
  });
}

for (const file of dashboardFiles(dashboardRoot)) {
  try {
    const dashboard = JSON.parse(fs.readFileSync(path.join(dashboardRoot, file), "utf8"));
    if (!dashboard.uid) {
      errors.push(`${file}: dashboard UID is missing`);
    } else if (seenUids.has(dashboard.uid)) {
      errors.push(
        `${file}: duplicate UID ${dashboard.uid} also used by ${seenUids.get(dashboard.uid)}`,
      );
    } else {
      seenUids.set(dashboard.uid, file);
    }
  } catch (error) {
    errors.push(`${file}: invalid JSON: ${error.message}`);
  }
}

function validateDashboard(file, { imported = false, officialMap = false } = {}) {
  const fullPath = path.join(dashboardRoot, file);
  if (!fs.existsSync(fullPath)) {
    errors.push(`${file}: missing dashboard`);
    return;
  }

  let dashboard;
  try {
    dashboard = JSON.parse(fs.readFileSync(fullPath, "utf8"));
  } catch (error) {
    errors.push(`${file}: invalid JSON: ${error.message}`);
    return;
  }

  let mapVariable;
  let geomapCount = 0;

  visit(dashboard, (node, location) => {
    if (typeof node === "string") {
      if (node.includes("volkovlabs-form-panel")) {
        errors.push(`${file} ${location}: third-party form panel remains`);
      }
      if (/(^|[^A-Za-z0-9_])effective_cost\(/.test(node)) {
        errors.push(`${file} ${location}: unnamespaced TOU function remains`);
      }
      if (/tm_(?:lat|lng)_for_map\('\$\{map_url\}'/.test(node)) {
        errors.push(`${file} ${location}: map variable is interpolated without SQL escaping`);
      }
      if (node.includes("raw.githubusercontent.com")) {
        errors.push(`${file} ${location}: auto-loaded remote asset remains`);
      }
      if (privateIp.test(node)) errors.push(`${file} ${location}: private IP address remains`);
      return;
    }

    if (!node || Array.isArray(node) || typeof node !== "object") return;

    if (("gridPos" in node || "targets" in node) && typeof node.type === "string") {
      if (imported && !allowedPanelTypes.has(node.type)) {
        errors.push(`${file} ${location}: unsupported panel ${node.type}`);
      }

      if (node.type === "geomap") {
        geomapCount += 1;
        if (
          node.options?.basemap?.type !== "xyz" ||
          node.options?.basemap?.config?.url !== "${map_url}"
        ) {
          errors.push(`${file} ${location}: geomap does not use the selected safe map source`);
        }
      }
    }

    for (const key of ["rawSql", "rawQuery", "query", "definition"]) {
      if (typeof node[key] === "string" && writeSql.test(node[key])) {
        errors.push(`${file} ${location}.${key}: write-capable SQL detected`);
      }
    }

    if (node.name === "map_url") {
      mapVariable = node;
      if (node.current?.value !== amapUrl) {
        errors.push(`${file} ${location}: mainland-safe AMap is not the default`);
      }
      if (node.skipUrlSync !== true) {
        errors.push(`${file} ${location}: map source can be overridden through dashboard URLs`);
      }
      if (
        !Array.isArray(node.options) ||
        node.options.length !== allowedMapUrls.size ||
        node.options.some((option) => !allowedMapUrls.has(option.value))
      ) {
        errors.push(`${file} ${location}: unexpected map-provider list`);
      }
    }
  });

  if (officialMap) {
    if (!mapVariable) errors.push(`${file}: map source variable is missing`);
    if (geomapCount < 1) errors.push(`${file}: expected a geomap panel`);

    const geomapSql = (dashboard.panels ?? [])
      .filter((panel) => panel.type === "geomap")
      .flatMap((panel) => panel.targets ?? [])
      .map((target) => target.rawSql ?? "")
      .join("\n");

    if (!geomapSql.includes("tm_lat_for_map(${map_url:sqlstring}")) {
      errors.push(`${file}: latitude is not converted for the selected map source`);
    }
    if (!geomapSql.includes("tm_lng_for_map(${map_url:sqlstring}")) {
      errors.push(`${file}: longitude is not converted for the selected map source`);
    }
  }
}

for (const file of importedFiles) validateDashboard(file, { imported: true });
for (const file of officialMapFiles) validateDashboard(file, { officialMap: true });

if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exit(1);
}

console.log(
  `Validated ${importedFiles.size} sanitized read-only dashboards and ${officialMapFiles.size} official China map dashboards.`,
);
