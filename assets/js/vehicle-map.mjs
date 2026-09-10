export function parseMapPoints(raw) {
  try {
    const points = JSON.parse(raw || "[]");
    if (!Array.isArray(points)) return [];
    return points
      .filter((p) => p && ["number", "string"].includes(typeof p.latitude) &&
        ["number", "string"].includes(typeof p.longitude) &&
        String(p.latitude).trim() !== "" && String(p.longitude).trim() !== "")
      .map((p) => ({ latitude: Number(p.latitude), longitude: Number(p.longitude) }))
      .filter((p) => Number.isFinite(p.latitude) && Number.isFinite(p.longitude) &&
        Math.abs(p.latitude) <= 90 && Math.abs(p.longitude) <= 180);
  } catch {
    return [];
  }
}

// Display conversion only, matching the project's tm_wgs84_to_gcj02 SQL
// functions. Telemetry, exports and editable geofences remain in WGS84.
export function toGCJ02({ latitude: lat, longitude: lng }) {
  if (lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271)
    return [lng, lat];
  const pi = Math.PI;
  const x = lng - 105;
  const y = lat - 35;
  const common = (20 * Math.sin(6 * x * pi) + 20 * Math.sin(2 * x * pi)) * 2 / 3;
  let dlat = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x));
  dlat += common + (20 * Math.sin(y * pi) + 40 * Math.sin(y * pi / 3)) * 2 / 3;
  dlat += (160 * Math.sin(y * pi / 12) + 320 * Math.sin(y * pi / 30)) * 2 / 3;
  let dlng = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
  dlng += common + (20 * Math.sin(x * pi) + 40 * Math.sin(x * pi / 3)) * 2 / 3;
  dlng += (150 * Math.sin(x * pi / 12) + 300 * Math.sin(x * pi / 30)) * 2 / 3;
  const rad = lat / 180 * pi;
  const magic = 1 - 0.00669342162296594323 * Math.sin(rad) ** 2;
  const sqrt = Math.sqrt(magic);
  dlat = dlat * 180 / ((6378245 * (1 - 0.00669342162296594323)) / (magic * sqrt) * pi);
  dlng = dlng * 180 / (6378245 / sqrt * Math.cos(rad) * pi);
  return [lng + dlng, lat + dlat];
}

export const amapStyle = (theme) => theme === "dark" ? "amap://styles/dark" : "amap://styles/normal";

let sdk;
export function loadAMap(config, win = window, doc = document) {
  if (sdk) {
    if (sdk.key !== config.key)
      return Promise.reject(new Error("地图配置已更新，请重新加载页面"));
    return sdk.promise;
  }
  if (!config.key || config.service_host !== "/_AMapService")
    return Promise.reject(new Error("请在系统设置中保存高德地图 Key 和安全密钥"));

  win._AMapSecurityConfig = { serviceHost: win.location.origin + config.service_host };
  const script = doc.createElement("script");
  const callback = "__teslamateAMapReady";
  const promise = new Promise((resolve, reject) => {
    const timer = win.setTimeout(() => fail(), 15000);
    const fail = () => {
      win.clearTimeout(timer);
      script.remove();
      sdk = undefined;
      win[callback] = () => {};
      reject(new Error("高德地图加载失败，请检查网络、Key 和域名白名单"));
    };
    win[callback] = () => {
      if (!win.AMap?.Map) return fail();
      win.clearTimeout(timer);
      resolve(win.AMap);
    };
    script.onerror = fail;
    script.async = true;
    script.referrerPolicy = "strict-origin-when-cross-origin";
    script.src = "https://webapi.amap.com/maps?" + new URLSearchParams({
      v: "2.0", key: config.key, callback, plugin: "AMap.Scale,AMap.ToolBar",
    });
    doc.head.appendChild(script);
  });
  sdk = { key: config.key, promise };
  return promise;
}

export function createAMapAdapter(AMap, canvas, { theme, mode, ready, failed }) {
  const map = new AMap.Map(canvas, {
    viewMode: "2D", zoom: 15, resizeEnable: true,
    mapStyle: amapStyle(theme), scrollWheel: false, showIndoorMap: false,
  });
  map.on("complete", ready);
  map.on("error", failed);
  if (AMap.Scale) map.addControl(new AMap.Scale());
  if (AMap.ToolBar) map.addControl(new AMap.ToolBar({ position: "LT" }));
  let marker, route, start, end;
  return {
    render(points) {
      const coordinates = points.map(toGCJ02);
      if (mode === "route" && coordinates.length > 1) {
        if (!route) {
          route = new AMap.Polyline({ path: coordinates, strokeColor: "#4f7cff", strokeWeight: 5, strokeOpacity: 0.9 });
          start = new AMap.Marker({ position: coordinates[0], title: "行程起点" });
          end = new AMap.Marker({ position: coordinates.at(-1), title: "行程终点" });
          map.add([route, start, end]);
        } else {
          route.setPath(coordinates);
          start.setPosition(coordinates[0]);
          end.setPosition(coordinates.at(-1));
        }
        map.setFitView([route], true, [28, 28, 28, 28], 16);
      } else if (coordinates.length) {
        if (!marker) {
          marker = new AMap.Marker({ position: coordinates[0], title: "车辆位置" });
          map.add(marker);
          map.setZoomAndCenter(15, coordinates[0], true);
        } else {
          marker.setPosition(coordinates[0]);
          if (!map.getBounds().contains(coordinates[0])) map.setCenter(coordinates[0], true);
        }
      }
    },
    setTheme(value) { map.setMapStyle(amapStyle(value)); },
    resize() { map.resize(); },
    destroy() { map.destroy(); },
  };
}

export function createVehicleMapHook(createLeaflet, dependencies = {}) {
  const win = dependencies.window || globalThis.window;
  const doc = dependencies.document || globalThis.document;
  const fetchConfig = dependencies.fetchConfig || (async (signal) => {
    const response = await win.fetch("/maps/config", {
      signal, credentials: "same-origin", cache: "no-store",
    });
    if (!response.ok) throw new Error("无法读取地图设置，请重新登录或刷新页面");
    return response.json();
  });
  const loadSDK = dependencies.loadSDK || loadAMap;

  return {
    mounted() {
      this.disposed = false;
      this.el.classList.add("vehicle-map");
      this.canvas = doc.createElement("div");
      this.canvas.className = "vehicle-map__canvas";
      this.canvas.setAttribute("aria-label", "车辆位置地图");
      this.status = doc.createElement("div");
      this.status.className = "vehicle-map__status";
      this.status.setAttribute("role", "status");
      this.statusText = doc.createElement("span");
      this.reload = doc.createElement("button");
      this.reload.type = "button";
      this.reload.className = "button is-small";
      this.reload.textContent = "重新加载页面";
      this.reload.onclick = () => win.location.reload();
      this.status.append(this.statusText, this.reload);
      this.el.replaceChildren(this.canvas, this.status);
      this.showStatus("正在加载地图…");
      this.abort = new AbortController();
      this.onTheme = () => this.adapter?.setTheme(doc.documentElement.dataset.theme || "light");
      win.addEventListener("themechange", this.onTheme);
      this.resizeObserver = win.ResizeObserver ? new win.ResizeObserver(() => this.adapter?.resize()) : null;
      this.resizeObserver?.observe(this.el);
      this.loading = this.startMap(fetchConfig, loadSDK, createLeaflet, win, doc);
    },

    showStatus(message, error = false) {
      this.status.hidden = !message;
      this.statusText.textContent = message;
      this.reload.hidden = !error;
    },

    async startMap(fetchConfig, loadSDK, createLeaflet, win, doc) {
      this.timeout = win.setTimeout(() => this.abort.abort(), 15000);
      try {
        const config = await fetchConfig(this.abort.signal);
        win.clearTimeout(this.timeout);
        if (this.disposed) return;
        const AMap = config.provider === "amap" ? await loadSDK(config, win, doc) : null;
        if (this.disposed) return;
        if (!["amap", "openstreetmap"].includes(config.provider)) throw new Error("地图提供商配置无效");
        this.el.dataset.mapProvider = config.provider;
        const options = {
          theme: doc.documentElement.dataset.theme || "light",
          mode: this.el.dataset.mode,
          ready: () => {
            if (!this.disposed) {
              win.clearTimeout(this.timeout);
              this.ready = true;
              this.showStatus("");
            }
          },
          failed: () => {
            if (!this.disposed) {
              this.ready = false;
              this.showStatus("地图加载失败，请检查网络或地图 Key 配置", true);
            }
          },
        };
        this.timeout = win.setTimeout(options.failed, 20000);
        this.adapter = AMap
          ? createAMapAdapter(AMap, this.canvas, options)
          : createLeaflet(this.canvas, options);
        this.updated();
      } catch (error) {
        win.clearTimeout(this.timeout);
        if (!this.disposed) this.showStatus(
          error.name === "AbortError" ? "读取地图设置超时，请重新加载页面" : error.message, true,
        );
      }
    },

    updated() {
      if (!this.adapter || this.lastPoints === this.el.dataset.points) return;
      const points = parseMapPoints(this.el.dataset.points);
      if (!points.length) {
        this.showStatus("暂无有效的位置坐标");
        return;
      }
      this.lastPoints = this.el.dataset.points;
      this.adapter.render(points);
      if (this.ready) this.showStatus("");
    },

    destroyed() {
      this.disposed = true;
      this.abort?.abort();
      win.clearTimeout(this.timeout);
      win.removeEventListener("themechange", this.onTheme);
      this.resizeObserver?.disconnect();
      this.adapter?.destroy();
      if (this.reload) this.reload.onclick = null;
    },
  };
}
