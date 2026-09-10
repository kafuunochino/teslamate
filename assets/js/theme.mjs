export const THEME_STORAGE_KEY = "teslamate:theme-mode";

function normalizeMode(value) {
  return value === "light" || value === "dark" ? value : "system";
}

export function initializeTheme(win, doc) {
  if (win.teslamateTheme) {
    win.teslamateTheme.syncControls();
    return win.teslamateTheme;
  }

  const media = win.matchMedia("(prefers-color-scheme: dark)");
  let mode = "system";
  try {
    mode = normalizeMode(win.localStorage.getItem(THEME_STORAGE_KEY));
  } catch (_error) {
    // Theme switching remains available when browser storage is disabled.
  }

  const getTheme = () =>
    mode === "system" ? (media.matches ? "dark" : "light") : mode;

  function syncControls(root = doc) {
    const dark = getTheme() === "dark";
    root.querySelectorAll("[data-theme-toggle]").forEach((button) => {
      button.setAttribute("aria-pressed", String(dark));
      button.setAttribute(
        "title",
        (mode === "system" ? "当前跟随系统；" : "") +
          (dark ? "切换到浅色模式" : "切换到深色模式"),
      );
      const icon = button.querySelector("[data-theme-icon]");
      if (icon) {
        icon.classList.toggle("mdi-weather-night", dark);
        icon.classList.toggle("mdi-white-balance-sunny", !dark);
      }
      const label = button.querySelector("[data-theme-label]");
      if (label) label.textContent = dark ? "深色" : "浅色";
    });
    root.querySelectorAll("[data-theme-system]").forEach((button) => {
      button.hidden = mode === "system";
    });
    root.querySelectorAll("[data-theme-mode-select]").forEach((select) => {
      select.value = mode;
    });
  }

  function apply() {
    const theme = getTheme();
    doc.documentElement.setAttribute("data-theme-mode", mode);
    doc.documentElement.setAttribute("data-theme", theme);
    syncControls();
    win.dispatchEvent(
      new win.CustomEvent("themechange", { detail: { theme, mode } }),
    );
  }

  function setMode(value) {
    mode = normalizeMode(value);
    try {
      if (mode === "system") win.localStorage.removeItem(THEME_STORAGE_KEY);
      else win.localStorage.setItem(THEME_STORAGE_KEY, mode);
    } catch (_error) {
      // The current page still changes even if the preference cannot be saved.
    }
    apply();
  }

  const controller = {
    getMode: () => mode,
    getTheme,
    setMode,
    syncControls,
  };
  win.teslamateTheme = controller;

  const onSystemChange = () => {
    if (mode === "system") apply();
  };
  if (media.addEventListener) media.addEventListener("change", onSystemChange);
  else media.addListener(onSystemChange);

  win.addEventListener("storage", (event) => {
    if (event.key === THEME_STORAGE_KEY || event.key === null) {
      mode = normalizeMode(event.newValue);
      apply();
    }
  });

  doc.addEventListener("click", (event) => {
    if (event.target.closest?.("[data-theme-toggle]")) {
      setMode(getTheme() === "dark" ? "light" : "dark");
    } else if (event.target.closest?.("[data-theme-system]")) {
      setMode("system");
    }
  });
  doc.addEventListener("DOMContentLoaded", () => syncControls(), {
    once: true,
  });
  win.addEventListener("phx:navigate", () => syncControls());
  win.addEventListener("phx:page-loading-stop", () => syncControls());

  apply();
  return controller;
}
