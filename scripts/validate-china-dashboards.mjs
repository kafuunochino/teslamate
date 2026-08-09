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

const categoryCenters = new Map([
  ["overview/overview-center.json", ["tmOverviewHubCN", "Nr4ofiDZk"]],
  ["driving/driving-center.json", ["tmDrivingHubCN", "tmDrivingCN"]],
  ["charging/charging-center.json", ["tmChargingHubCN", "tmChargingCN"]],
  ["energy/energy-center.json", ["tmEnergyHubCN", "tmEnergyCN"]],
  ["analysis/analysis-center.json", ["tmAnalysisHubCN", "tmAnalysisCN"]],
  ["system/system-center.json", ["tmSystemHubCN", "tmSystemCN"]],
]);

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

    const visiblePanels = (dashboard.panels ?? []).filter(
      (panel) => panel.gridPos && panel.type !== "row",
    );
    for (const panel of visiblePanels) {
      const { h, w, x, y } = panel.gridPos;
      if (h < 1 || w < 1 || x < 0 || y < 0 || x + w > 24) {
        errors.push(
          `${normalizedFile}: panel ${panel.id} has an invalid grid position`,
        );
      }
    }
    for (let left = 0; left < visiblePanels.length; left += 1) {
      for (let right = left + 1; right < visiblePanels.length; right += 1) {
        const a = visiblePanels[left];
        const b = visiblePanels[right];
        if (
          a.gridPos.x < b.gridPos.x + b.gridPos.w &&
          b.gridPos.x < a.gridPos.x + a.gridPos.w &&
          a.gridPos.y < b.gridPos.y + b.gridPos.h &&
          b.gridPos.y < a.gridPos.y + a.gridPos.h
        ) {
          errors.push(
            `${normalizedFile}: panels ${a.id} and ${b.id} overlap in the dashboard grid`,
          );
        }
      }
    }
  } catch (error) {
    errors.push(`${normalizedFile}: invalid JSON: ${error.message}`);
  }
}

for (const [file, [uid, folderUid]] of categoryCenters) {
  const fullPath = path.join(dashboardRoot, file);
  if (!fs.existsSync(fullPath)) {
    errors.push(`${file}: missing category center`);
    continue;
  }

  const center = JSON.parse(fs.readFileSync(fullPath, "utf8"));
  if (center.uid !== uid) {
    errors.push(`${file}: category center UID changed`);
  }
  if ((center.panels ?? []).filter(({ type }) => type === "stat").length < 5) {
    errors.push(`${file}: category summary is too narrow`);
  }
  if (
    !(center.panels ?? []).some(
      (panel) =>
        panel.type === "dashlist" && panel.options?.folderUID === folderUid,
    )
  ) {
    errors.push(`${file}: missing complete category list`);
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
    errors.push(
      `${sentryFile}: panel ${panelId} does not render no-data as zero`,
    );
  }
}

const speedTemperatureFile = "energy/speed-temperature.json";
const speedTemperatureDashboard = JSON.parse(
  fs.readFileSync(path.join(dashboardRoot, speedTemperatureFile), "utf8"),
);
const capacityVariable = speedTemperatureDashboard.templating?.list?.find(
  ({ name }) => name === "current_capacity",
);
if (
  capacityVariable?.current?.value !== "75" ||
  !capacityVariable?.query?.includes(
    "COALESCE(ROUND(Capacity::numeric, 1), 75)",
  )
) {
  errors.push(`${speedTemperatureFile}: battery-capacity fallback is missing`);
}
for (const [panelId, minimumWidth] of [
  [26, 24],
  [15, 24],
  [24, 24],
  [16, 12],
  [27, 12],
  [22, 12],
  [28, 12],
  [14, 12],
  [11, 12],
]) {
  const panel = speedTemperatureDashboard.panels?.find(
    ({ id }) => id === panelId,
  );
  if ((panel?.gridPos?.w ?? 0) < minimumWidth) {
    errors.push(`${speedTemperatureFile}: panel ${panelId} is too narrow`);
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
if (
  (homeDashboard.panels ?? []).some(
    (panel) => panel.type === "dashlist" && panel.gridPos?.w < 12,
  )
) {
  errors.push("internal/home.json: category lists are too narrow");
}
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
  errors.push(
    "internal/home.json: external content remains on the default home page",
  );
}
for (const [panelType, minimum] of [
  ["stat", 10],
  ["timeseries", 2],
  ["table", 2],
  ["dashlist", 8],
]) {
  if (
    (homeDashboard.panels ?? []).filter(({ type }) => type === panelType)
      .length < minimum
  ) {
    errors.push(
      `internal/home.json: missing comprehensive ${panelType} panels`,
    );
  }
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

const categoryFolderTitles = [
  "TeslaMate · 实时总览",
  "TeslaMate · 行程与足迹",
  "TeslaMate · 充电与费用",
  "TeslaMate · 电池与能效",
  "TeslaMate · 分析与洞察",
  "TeslaMate · 系统与数据",
  "TeslaMate · 详细记录",
  "TeslaMate · 专题报告",
];
for (const configFile of [
  "grafana/dashboards.yml",
  "grafana/dashboards-native.yml",
]) {
  const config = fs.readFileSync(path.join(projectRoot, configFile), "utf8");
  for (const folderTitle of categoryFolderTitles) {
    if (!config.includes(`folder: "${folderTitle}"`)) {
      errors.push(`${configFile}: missing category folder ${folderTitle}`);
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

const rootLayout = fs.readFileSync(
  path.join(
    projectRoot,
    "lib",
    "teslamate_web",
    "templates",
    "layout",
    "root.html.heex",
  ),
  "utf8",
);
for (const [route, label] of [
  [":home", "首页"],
  [":trips", "行程轨迹"],
  [":battery", "电池"],
  [":charging", "充电"],
  [":analysis", "分析"],
  ['~p"/vehicles"', "车辆中心"],
  ['~p"/admin/users"', "用户与权限"],
]) {
  if (!rootLayout.includes(route) || !rootLayout.includes(label)) {
    errors.push(`root.html.heex: unified navigation omits ${label}`);
  }
}

const router = fs.readFileSync(
  path.join(projectRoot, "lib", "teslamate_web", "router.ex"),
  "utf8",
);
for (const route of [
  'get "/sign_in"',
  'post "/sign_in"',
  'get "/register"',
  'live "/trips"',
  'live "/battery"',
  'live "/charging"',
  'live "/analysis"',
  'live "/vehicles"',
  'live "/users"',
]) {
  if (!router.includes(route)) {
    errors.push(`router.ex: unified platform route is missing: ${route}`);
  }
}

for (const formatterFile of [
  "treefmt.toml",
  "nix/flake-modules/formatter.nix",
]) {
  const formatter = fs.readFileSync(
    path.join(projectRoot, formatterFile),
    "utf8",
  );
  if (!formatter.includes("grafana/dashboards/**/*.json")) {
    errors.push(
      `${formatterFile}: categorized dashboards are not excluded from reformatting`,
    );
  }
}

for (const [revisionFile, revisionMarker] of [
  ["Dockerfile", "ARG TESLAMATE_REVISION"],
  ["docker-compose.zh-CN.yml", "TESLAMATE_REVISION: ${TESLAMATE_REVISION:-}"],
  [".github/actions/build/action.yml", "TESLAMATE_REVISION=${{ github.sha }}"],
]) {
  const content = fs.readFileSync(path.join(projectRoot, revisionFile), "utf8");
  if (!content.includes(revisionMarker)) {
    errors.push(
      `${revisionFile}: Docker update checks cannot identify the build revision`,
    );
  }
}

const grafanaDockerfile = fs.readFileSync(
  path.join(projectRoot, "grafana", "Dockerfile"),
  "utf8",
);
for (const directAuthSetting of [
  "GF_AUTH_ANONYMOUS_ENABLED=false",
  "GF_AUTH_BASIC_ENABLED=true",
  "GF_AUTH_PROXY_ENABLED=false",
  "GF_AUTH_DISABLE_LOGIN_FORM=false",
  "GF_AUTH_DISABLE_SIGNOUT_MENU=false",
  "GF_USERS_ALLOW_SIGN_UP=false",
  "GF_SECURITY_ALLOW_EMBEDDING=false",
]) {
  if (!grafanaDockerfile.includes(directAuthSetting)) {
    errors.push(
      `grafana/Dockerfile: missing direct-login default ${directAuthSetting}`,
    );
  }
}
for (const unsafeAuthSetting of [
  "GF_AUTH_ANONYMOUS_ORG_NAME",
  "GF_AUTH_ANONYMOUS_ORG_ROLE",
  "GF_AUTH_PROXY_HEADER_NAME",
  "GF_AUTH_PROXY_HEADER_PROPERTY",
  "GF_AUTH_PROXY_AUTO_SIGN_UP",
  "GF_AUTH_PROXY_ENABLE_LOGIN_TOKEN",
  "GF_AUTH_PROXY_SYNC_ATTRIBUTES",
  "GF_SECURITY_ADMIN_PASSWORD=",
]) {
  if (grafanaDockerfile.includes(unsafeAuthSetting)) {
    errors.push(
      `grafana/Dockerfile: direct-login image must not set ${unsafeAuthSetting}`,
    );
  }
}
for (const disabledLayoutFlag of [
  "GF_FEATURE_TOGGLES_newPanelPadding=false",
  "GF_FEATURE_TOGGLES_dashboardNewLayouts=false",
]) {
  if (grafanaDockerfile.includes(disabledLayoutFlag)) {
    errors.push(
      `grafana/Dockerfile: Grafana 13 layout disabled by ${disabledLayoutFlag}`,
    );
  }
}

function serviceBlock(compose, serviceName) {
  const match = compose.match(
    new RegExp(
      `^  ${serviceName}:\\n([\\s\\S]*?)(?=^  [a-zA-Z0-9_-]+:\\s*$|^volumes:\\s*$|(?![\\s\\S]))`,
      "m",
    ),
  );
  return match?.[0] ?? "";
}

for (const composeFile of [
  "docker-compose.zh-CN.yml",
  "docker-compose.1panel.yml",
]) {
  const compose = fs.readFileSync(path.join(projectRoot, composeFile), "utf8");
  const appService = serviceBlock(compose, "teslamate");
  const grafanaService = serviceBlock(compose, "grafana");

  for (const required of [
    "PORT: 3000",
    '"127.0.0.1:3000:3000"',
    "SECRET_KEY_BASE:",
    "SIGNING_SALT:",
  ]) {
    if (!appService.includes(required)) {
      errors.push(`${composeFile}: unified service is missing ${required}`);
    }
  }

  if (/4000:4000|PORT:\s*4000/.test(compose)) {
    errors.push(`${composeFile}: legacy port 4000 is still exposed`);
  }
  if (!grafanaService.includes('profiles: ["legacy-grafana"]')) {
    errors.push(`${composeFile}: Grafana must remain an opt-in legacy profile`);
  }
  for (const directLoginSetting of [
    'GF_AUTH_ANONYMOUS_ENABLED: "false"',
    'GF_AUTH_BASIC_ENABLED: "true"',
    'GF_AUTH_PROXY_ENABLED: "false"',
    'GF_AUTH_DISABLE_LOGIN_FORM: "false"',
    'GF_AUTH_DISABLE_SIGNOUT_MENU: "false"',
    'GF_USERS_ALLOW_SIGN_UP: "false"',
  ]) {
    if (!grafanaService.includes(directLoginSetting)) {
      errors.push(
        `${composeFile}: legacy Grafana direct login is missing ${directLoginSetting}`,
      );
    }
  }
  if (/^\s{4}ports:/m.test(grafanaService)) {
    errors.push(`${composeFile}: legacy Grafana must not publish a host port`);
  }
  if (!grafanaService.includes("teslamate-grafana-data:/var/lib/grafana")) {
    errors.push(`${composeFile}: legacy Grafana data volume is not preserved`);
  }
}

const onePanelCompose = fs.readFileSync(
  path.join(projectRoot, "docker-compose.1panel.yml"),
  "utf8",
);
if (/^  database:/m.test(onePanelCompose)) {
  errors.push(
    "docker-compose.1panel.yml: must not create or replace PostgreSQL",
  );
}
for (const externalDatabaseSetting of [
  "DATABASE_HOST: ${DATABASE_HOST:-postgres}",
  "DATABASE_PORT: ${DATABASE_PORT:-5432}",
  "external: true",
  "name: ${PANEL_NETWORK:-1panel-network}",
]) {
  if (!onePanelCompose.includes(externalDatabaseSetting)) {
    errors.push(
      `docker-compose.1panel.yml: missing external database setting ${externalDatabaseSetting}`,
    );
  }
}

const onePanelGrafanaVolume =
  onePanelCompose.match(
    /^  teslamate-grafana-data:\n(?: {4}[^\n]*(?:\n|$))*/m,
  )?.[0] ?? "";

for (const preservedVolumeSetting of [
  "external: true",
  "name: ${GRAFANA_VOLUME_NAME:-teslamate-grafana-data}",
]) {
  if (!onePanelGrafanaVolume.includes(preservedVolumeSetting)) {
    errors.push(
      `docker-compose.1panel.yml: legacy Grafana volume is missing ${preservedVolumeSetting}`,
    );
  }
}

if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exit(1);
}

console.log(
  `Validated all ${allDashboardFiles.length} dashboards (${importedFiles.size} imported enhancements and ${officialMapFiles.size} official China map dashboards).`,
);
