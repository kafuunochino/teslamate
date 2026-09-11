import { createVehicleMapHook, loadAMap, toGCJ02 } from "./vehicle-map.mjs";

// Invert the display transform before saving an edited center. Existing stored
// WGS84 coordinates must never be rewritten merely by opening the editor.
export function fromGCJ02({ latitude, longitude }) {
  let point = { latitude, longitude };
  for (let i = 0; i < 10; i++) {
    const [lng, lat] = toGCJ02(point);
    const dlat = lat - latitude;
    const dlng = lng - longitude;
    point = {
      latitude: point.latitude - dlat,
      longitude: point.longitude - dlng,
    };
    if (Math.max(Math.abs(dlat), Math.abs(dlng)) < 1e-9) break;
  }
  return point;
}

export function parseGeoFence(values) {
  const result = {};
  for (const name of ["latitude", "longitude", "radius"]) {
    const value = values[name];
    if (
      !["number", "string"].includes(typeof value) ||
      String(value).trim() === ""
    )
      return null;
    result[name] = Number(value);
  }
  if (
    !Object.values(result).every(Number.isFinite) ||
    Math.abs(result.latitude) > 90 ||
    Math.abs(result.longitude) > 180 ||
    !Number.isInteger(result.radius) ||
    result.radius <= 0 ||
    result.radius >= 5000
  )
    return null;
  return result;
}

const radiusInRange = (value) => Math.max(1, Math.min(4999, Math.round(value)));
const pointFromAMap = (point) => ({
  latitude: point.getLat(),
  longitude: point.getLng(),
});

export function createAMapGeoFenceAdapter(AMap, canvas, { ready, failed }) {
  const map = new AMap.Map(canvas, {
    viewMode: "2D",
    mapStyle: "amap://styles/normal",
    zoom: 17,
    scrollWheel: false,
    showIndoorMap: false,
  });
  map.on("complete", ready);
  map.on("error", failed);
  if (AMap.Scale) map.addControl(new AMap.Scale());
  if (AMap.ToolBar) map.addControl(new AMap.ToolBar({ position: "LT" }));
  const geocoder = new AMap.Geocoder();
  let circle,
    editor,
    current,
    listener,
    rendering = false,
    disposed = false;

  const render = (value, fit = true) => {
    rendering = true;
    current = { ...value };
    editor?.close();
    const center = toGCJ02(value);
    if (!circle) {
      circle = new AMap.Circle({
        center,
        radius: value.radius,
        strokeColor: "#4f7cff",
        strokeWeight: 3,
        fillColor: "#4f7cff",
        fillOpacity: 0.18,
      });
      map.add(circle);
      editor = new AMap.CircleEditor(map, circle);
      editor.on("move", changed);
      editor.on("adjust", changed);
    } else {
      circle.setCenter(center);
      circle.setRadius(value.radius);
    }
    editor.open();
    if (fit) map.setFitView([circle], true, [40, 40, 40, 40], 18);
    rendering = false;
  };

  function changed() {
    if (disposed || rendering || !current) return;
    const displayed = pointFromAMap(circle.getCenter());
    const [lng, lat] = toGCJ02(current);
    const sameCenter =
      Math.abs(displayed.latitude - lat) < 1e-9 &&
      Math.abs(displayed.longitude - lng) < 1e-9;
    const center = sameCenter ? current : fromGCJ02(displayed);
    const radius = radiusInRange(circle.getRadius());
    const value = parseGeoFence({ ...center, radius });
    if (!value) return;
    current = value;
    if (radius !== circle.getRadius()) render(value, false);
    listener?.(value);
  }

  map.on("click", (event) => {
    if (!current || disposed) return;
    const value = parseGeoFence({
      ...fromGCJ02(pointFromAMap(event.lnglat)),
      radius: current.radius,
    });
    if (!value) return;
    render(value, false);
    listener?.(value);
  });

  return {
    render,
    onChange(callback) {
      listener = callback;
    },
    search(query) {
      return new Promise((resolve, reject) => {
        geocoder.getLocation(query, (status, result) => {
          if (status === "no_data") return resolve([]);
          if (status !== "complete")
            return reject(new Error("地点搜索失败，请检查地图配置或稍后重试"));
          resolve(
            (result.geocodes || []).slice(0, 5).map((item) => ({
              label: item.formattedAddress,
              ...fromGCJ02(pointFromAMap(item.location)),
            })),
          );
        });
      });
    },
    resize() {
      map.resize();
    },
    destroy() {
      disposed = true;
      listener = null;
      editor?.close();
      map.destroy();
    },
  };
}

export function createLeafletGeoFenceAdapter(
  L,
  geocoder,
  canvas,
  { theme, ready, failed },
) {
  const map = new L.Map(canvas, { scrollWheelZoom: false });
  const tiles = new L.TileLayer(
    "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
    {
      maxZoom: 19,
      attribution: "© OpenStreetMap",
    },
  );
  let loaded = false,
    circle,
    current,
    listener,
    rendering = false,
    disposed = false;
  tiles.on("tileload", () => {
    loaded = true;
    ready();
  });
  tiles.on("tileerror", () => {
    if (!loaded) failed();
  });
  tiles.addTo(map);
  const setTheme = (value) =>
    canvas.classList.toggle("vehicle-map--osm-dark", value === "dark");
  setTheme(theme);

  const render = (value, fit = true) => {
    rendering = true;
    current = { ...value };
    circle?.pm.disable();
    const center = [value.latitude, value.longitude];
    if (!circle) {
      circle = new L.Circle(center, {
        radius: value.radius,
        color: "#4f7cff",
        weight: 3,
        fillOpacity: 0.18,
      }).addTo(map);
      circle.on("pm:edit", () => {
        if (disposed || rendering) return;
        const center = circle.getLatLng();
        const value = parseGeoFence({
          latitude: center.lat,
          longitude: center.lng,
          radius: radiusInRange(circle.getRadius()),
        });
        if (!value) return;
        current = value;
        if (value.radius !== circle.getRadius()) render(value, false);
        listener?.(value);
      });
    } else {
      circle.setLatLng(center);
      circle.setRadius(value.radius);
    }
    circle.pm.enable({ preventMarkerRemoval: true });
    if (fit)
      map.fitBounds(circle.getBounds(), {
        padding: [40, 40],
        maxZoom: 18,
        animate: false,
      });
    rendering = false;
  };
  map.on("click", ({ latlng }) => {
    if (!current || disposed) return;
    const value = parseGeoFence({
      latitude: latlng.lat,
      longitude: latlng.lng,
      radius: current.radius,
    });
    if (!value) return;
    render(value, false);
    listener?.(value);
  });
  return {
    render,
    onChange(callback) {
      listener = callback;
    },
    async search(query) {
      const results = await geocoder.geocode(query);
      return results.slice(0, 5).map((item) => ({
        label: item.name,
        latitude: item.center.lat,
        longitude: item.center.lng,
      }));
    },
    setTheme,
    resize() {
      map.invalidateSize({ pan: false });
    },
    destroy() {
      disposed = true;
      listener = null;
      circle?.pm.disable();
      map.remove();
    },
  };
}

export function createGeoFenceMapHook(createLeaflet, dependencies = {}) {
  const win = dependencies.window || globalThis.window;
  const doc = dependencies.document || globalThis.document;
  const loadSDK = dependencies.loadSDK || loadAMap;
  const base = createVehicleMapHook(createLeaflet, {
    ...dependencies,
    createAMap: dependencies.createAMap || createAMapGeoFenceAdapter,
    async loadSDK(config, win, doc) {
      const sdk = await loadSDK(config, win, doc);
      if (sdk.CircleEditor && sdk.Geocoder) return sdk;
      await new Promise((resolve, reject) => {
        const timer = win.setTimeout(
          () => reject(new Error("地图编辑工具加载超时，请重新加载页面")),
          15000,
        );
        sdk.plugin(["AMap.CircleEditor", "AMap.Geocoder"], () => {
          win.clearTimeout(timer);
          if (sdk.CircleEditor && sdk.Geocoder) resolve();
          else reject(new Error("地图编辑工具加载失败，请重新加载页面"));
        });
      });
      return sdk;
    },
  });
  return {
    ...base,
    mounted() {
      this.form = this.el.closest("form");
      this.fields = Object.fromEntries(
        ["latitude", "longitude", "radius"].map((name) => [
          name,
          this.form.querySelector('[name="geo_fence[' + name + ']"]'),
        ]),
      );
      this.searchInput = this.form.querySelector("[data-geofence-query]");
      this.searchButton = this.form.querySelector("[data-geofence-search]");
      this.results = this.form.querySelector("[data-geofence-results]");
      this.searchStatus = this.form.querySelector(
        "[data-geofence-search-status]",
      );
      this.onRadius = () => this.updated();
      this.onSearch = () => this.search();
      this.onSearchKey = (event) => {
        if (event.key === "Enter") {
          event.preventDefault();
          event.stopPropagation();
          this.search();
        }
      };
      this.fields.radius.addEventListener("input", this.onRadius);
      this.searchButton.addEventListener("click", this.onSearch);
      this.searchInput.addEventListener("keydown", this.onSearchKey);
      this.searchButton.disabled = true;
      this.searchSequence = 0;
      base.mounted.call(this);
    },

    geometry() {
      return parseGeoFence(
        Object.fromEntries(
          Object.entries(this.fields).map(([name, field]) => [
            name,
            field.value,
          ]),
        ),
      );
    },

    updated() {
      if (!this.adapter || this.disposed) return;
      this.searchButton.disabled = !!this.searching;
      this.adapter.onChange((value) => this.writeGeometry(value));
      const value = this.geometry();
      if (!value) return;
      const signature = JSON.stringify(value);
      if (signature === this.lastGeometry) return;
      this.lastGeometry = signature;
      this.adapter.render(value);
    },

    writeGeometry(value) {
      if (this.disposed || !parseGeoFence(value)) return;
      this.lastGeometry = JSON.stringify(value);
      for (const [name, field] of Object.entries(this.fields))
        field.value = value[name];
      // One bubbling input event sends the entire form, including both hidden
      // coordinates, through LiveView validation before a later save.
      this.fields.radius.dispatchEvent(
        new win.Event("input", { bubbles: true }),
      );
    },

    async search() {
      const query = this.searchInput.value.trim();
      if (!query || !this.adapter || this.searching) return;
      const sequence = ++this.searchSequence;
      this.searching = true;
      this.searchButton.disabled = true;
      this.results.replaceChildren();
      this.searchStatus.textContent = "正在搜索地点…";
      try {
        const timeout = new Promise((_, reject) => {
          this.searchTimer = win.setTimeout(
            () => reject(new Error("地点搜索超时，请稍后重试")),
            15000,
          );
        });
        const results = await Promise.race([
          this.adapter.search(query),
          timeout,
        ]);
        if (this.disposed || sequence !== this.searchSequence) return;
        const valid = results.filter((item) =>
          parseGeoFence({ ...item, radius: 20 }),
        );
        this.searchStatus.textContent = valid.length
          ? "请选择地点，再确认地图中的位置和范围。"
          : "没有找到地点，请补充城市和详细地址。";
        for (const item of valid) {
          const button = doc.createElement("button");
          button.type = "button";
          button.className = "button geofence-search-result";
          button.textContent = item.label;
          button.onclick = () => {
            if (this.disposed) return;
            const value = {
              latitude: item.latitude,
              longitude: item.longitude,
              radius: this.geometry()?.radius || 20,
            };
            this.adapter.render(value);
            this.writeGeometry(value);
            this.results.replaceChildren();
            this.searchStatus.textContent =
              "已选中：" + item.label + "。保存后生效。";
          };
          this.results.append(button);
        }
      } catch (error) {
        if (!this.disposed && sequence === this.searchSequence)
          this.searchStatus.textContent =
            error.message || "地点搜索失败，请稍后重试";
      } finally {
        win.clearTimeout(this.searchTimer);
        if (!this.disposed && sequence === this.searchSequence) {
          this.searching = false;
          this.searchButton.disabled = false;
        }
      }
    },

    destroyed() {
      this.searchSequence++;
      win.clearTimeout(this.searchTimer);
      this.fields.radius.removeEventListener("input", this.onRadius);
      this.searchButton.removeEventListener("click", this.onSearch);
      this.searchInput.removeEventListener("keydown", this.onSearchKey);
      this.results.replaceChildren();
      base.destroyed.call(this);
    },
  };
}
