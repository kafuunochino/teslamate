import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const projectRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const dashboardRoot = path.join(projectRoot, "grafana", "dashboards");

const importedFiles = new Set([
  "analysis/amortization.json",
  "analysis/cost-savings.json",
  "analysis/vehicle-comparison.json",
  "charging/charging-costs-stats.json",
  "charging/charging-curve-stats.json",
  "charging/charging-health.json",
  "charging/dc-charging-curves-carrier.json",
  "charging/station-ranking.json",
  "driving/annual-summary.json",
  "driving/continuous-trips.json",
  "driving/driving-patterns.json",
  "driving/driving-score.json",
  "driving/mileage-stats.json",
  "driving/speed-rates.json",
  "driving/tracking-drives.json",
  "energy/range-degradation.json",
  "energy/regen-braking.json",
  "energy/sentry-drain.json",
  "energy/speed-temperature.json",
  "energy/tire-pressure.json",
  "energy/weather-efficiency.json",
  "overview/current-charge.json",
  "overview/current-drive.json",
  "overview/current-state.json",
  "system/incomplete-data.json",
]);

const officialMapFiles = new Set([
  "charging/charging-stats.json",
  "driving/trip.json",
  "driving/visited.json",
  "internal/charge-details.json",
  "internal/drive-details.json",
]);

const dashboardCategories = new Set([
  "analysis",
  "charging",
  "driving",
  "energy",
  "internal",
  "overview",
  "reports",
  "system",
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

const writeSql =
  /\b(insert|update|delete|drop|alter|truncate|grant|revoke|copy|call|do)\b/i;
const privateIp =
  /https?:\/\/(?:10\.|127\.|169\.254\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)/i;
const errors = [];
const seenUids = new Map();

function visit(node, callback, location = "root") {
  callback(node, location);
  if (Array.isArray(node)) {
    node.forEach((value, index) =>
      visit(value, callback, `${location}[${index}]`),
    );
  } else if (node && typeof node === "object") {
    Object.entries(node).forEach(([key, value]) =>
      visit(value, callback, `${location}.${key}`),
    );
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

const allDashboardFiles = dashboardFiles(dashboardRoot).map((file) =>
  file.split(path.sep).join("/"),
);

for (const normalizedFile of allDashboardFiles) {
  const [category, name] = normalizedFile.split("/");

  if (!name || !dashboardCategories.has(category)) {
    errors.push(`${normalizedFile}: dashboard is not in a supported category`);
  }

  try {
    const dashboard = JSON.parse(
      fs.readFileSync(path.join(dashboardRoot, normalizedFile), "utf8"),
    );
    if (!dashboard.uid) {
      errors.push(`${normalizedFile}: dashboard UID is missing`);
    } else if (seenUids.has(dashboard.uid)) {
      errors.push(
        `${normalizedFile}: duplicate UID ${dashboard.uid} also used by ${seenUids.get(dashboard.uid)}`,
      );
    } else {
      seenUids.set(dashboard.uid, normalizedFile);
    }
  } catch (error) {
    errors.push(`${normalizedFile}: invalid JSON: ${error.message}`);
  }
}

function validateDashboard(
  file,
  { imported = false, officialMap = false } = {},
) {
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
        errors.push(
          `${file} ${location}: map variable is interpolated without SQL escaping`,
        );
      }
      if (node.includes("raw.githubusercontent.com")) {
        errors.push(`${file} ${location}: auto-loaded remote asset remains`);
      }
      if (privateIp.test(node))
        errors.push(`${file} ${location}: private IP address remains`);
      return;
    }

    if (!node || Array.isArray(node) || typeof node !== "object") return;

    if (
      ("gridPos" in node || "targets" in node) &&
      typeof node.type === "string"
    ) {
      if (imported && !allowedPanelTypes.has(node.type)) {
        errors.push(`${file} ${location}: unsupported panel ${node.type}`);
      }

      if (node.type === "geomap") {
        geomapCount += 1;
        if (
          node.options?.basemap?.type !== "xyz" ||
          node.options?.basemap?.config?.url !== "${map_url}"
        ) {
          errors.push(
            `${file} ${location}: geomap does not use the selected safe map source`,
          );
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
        errors.push(
          `${file} ${location}: mainland-safe AMap is not the default`,
        );
      }
      if (node.skipUrlSync !== true) {
        errors.push(
          `${file} ${location}: map source can be overridden through dashboard URLs`,
        );
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
      errors.push(
        `${file}: latitude is not converted for the selected map source`,
      );
    }
    if (!geomapSql.includes("tm_lng_for_map(${map_url:sqlstring}")) {
      errors.push(
        `${file}: longitude is not converted for the selected map source`,
      );
    }
  }
}

for (const file of allDashboardFiles) {
  validateDashboard(file, {
    imported: importedFiles.has(file),
    officialMap: officialMapFiles.has(file),
  });
}

const sentryFile = "energy/sentry-drain.json";
const sentryDashboard = JSON.parse(
  fs.readFileSync(path.join(dashboardRoot, sentryFile), "utf8"),
);
const sentrySql = (sentryDashboard.panels ?? [])
  .flatMap((panel) => panel.targets ?? [])
  .map((target) => target.rawSql ?? "")
  .join("\n");

for (const requiredSql of [
  "NULLIF(c.efficiency, 0)",
  "start_ideal_range_km",
  "end_ideal_range_km",
  "ELSE d.distance",
  "generate_series(",
  "COALESCE(s.end_date, c.pe)",
]) {
  if (!sentrySql.includes(requiredSql)) {
    errors.push(`${sentryFile}: missing no-data fallback ${requiredSql}`);
  }
}

for (const panelId of [2, 3, 4, 5]) {
  const panel = sentryDashboard.panels?.find(({ id }) => id === panelId);
  if (panel?.fieldConfig?.defaults?.noValue !== "0") {
    errors.push(`${sentryFile}: panel ${panelId} does not render no-data as zero`);
  }
}

const categoryPaths = [
  "overview",
  "driving",
  "charging",
  "energy",
  "analysis",
  "system",
  "internal",
  "reports",
];

const homeDashboard = JSON.parse(
  fs.readFileSync(path.join(dashboardRoot, "internal", "home.json"), "utf8"),
);
const homeFolderUids = new Set(
  (homeDashboard.panels ?? [])
    .filter(({ type }) => type === "dashlist")
    .map((panel) => panel.options?.folderUID),
);
for (const folderUid of [
  "Nr4ofiDZk",
  "tmDrivingCN",
  "tmChargingCN",
  "tmEnergyCN",
  "tmAnalysisCN",
  "tmSystemCN",
]) {
  if (!homeFolderUids.has(folderUid)) {
    errors.push(`internal/home.json: missing category ${folderUid}`);
  }
}
const homeText = JSON.stringify(homeDashboard);
if (homeText.includes("https://") || homeText.includes("http://")) {
  errors.push("internal/home.json: external content remains on the default home page");
}

for (const [configFile, pathPrefix] of [
  ["grafana/dashboards.yml", "/dashboards"],
  ["grafana/dashboards-native.yml", "$TESLAMATE_DASHBOARDS_PATH"],
]) {
  const config = fs.readFileSync(path.join(projectRoot, configFile), "utf8");
  for (const category of categoryPaths) {
    if (!config.includes(`path: ${pathPrefix}/${category}`)) {
      errors.push(`${configFile}: missing provider for ${category}`);
    }
  }
}

const dockerDatasource = fs.readFileSync(
  path.join(projectRoot, "grafana", "datasource.yml"),
  "utf8",
);
if (/^\s+uid:/m.test(dockerDatasource)) {
  errors.push(
    "grafana/datasource.yml: Docker upgrades must preserve the UID of the existing named datasource",
  );
}

const nixModule = fs.readFileSync(
  path.join(projectRoot, "nix", "module.nix"),
  "utf8",
);
if (nixModule.includes('uid = "TeslaMate";')) {
  errors.push(
    "nix/module.nix: NixOS upgrades must preserve the UID of the existing named datasource",
  );
}

const layoutView = fs.readFileSync(
  path.join(projectRoot, "lib", "teslamate_web", "views", "layout_view.ex"),
  "utf8",
);
if (layoutView.includes('Path.wildcard("grafana/dashboards/*.json")')) {
  errors.push("layout_view.ex: dashboard navigation still scans only the old root directory");
}
for (const category of categoryPaths.slice(0, 6)) {
  if (!layoutView.includes(category)) {
    errors.push(`layout_view.ex: dashboard navigation omits ${category}`);
  }
}

for (const formatterFile of [
  "treefmt.toml",
  "nix/flake-modules/formatter.nix",
]) {
  const formatter = fs.readFileSync(path.join(projectRoot, formatterFile), "utf8");
  if (!formatter.includes("grafana/dashboards/**/*.json")) {
    errors.push(`${formatterFile}: categorized dashboards are not excluded from reformatting`);
  }
}

for (const [revisionFile, revisionMarker] of [
  ["Dockerfile", "ARG TESLAMATE_REVISION"],
  ["docker-compose.zh-CN.yml", "TESLAMATE_REVISION: ${TESLAMATE_REVISION:-}"],
  [".github/actions/build/action.yml", "TESLAMATE_REVISION=${{ github.sha }}"],
]) {
  const content = fs.readFileSync(path.join(projectRoot, revisionFile), "utf8");
  if (!content.includes(revisionMarker)) {
    errors.push(`${revisionFile}: Docker update checks cannot identify the build revision`);
  }
}

if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exit(1);
}

console.log(
  `Validated all ${allDashboardFiles.length} dashboards (${importedFiles.size} imported enhancements and ${officialMapFiles.size} official China map dashboards).`,
);
