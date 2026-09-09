const navbarBurger = document.querySelector(".navbar-burger");
if (navbarBurger) {
  navbarBurger.addEventListener("click", function () {
    const $target = document.getElementById(this.dataset.target);
    $target.classList.toggle("is-active");
    this.classList.toggle("is-active");
  });
}

const sidebar = document.getElementById("platform-sidebar");
const sidebarBackdrop = document.getElementById("sidebar-backdrop");
const sidebarOpen = document.getElementById("sidebar-open");
const sidebarClose = document.getElementById("sidebar-close");

const sidebarToggle = document.getElementById("sidebar-desktop-toggle");
const desktopSidebar = window.matchMedia("(min-width: 981px)");
let sidebarCollapsed = false;
try {
  sidebarCollapsed =
    localStorage.getItem("teslamate:sidebar-collapsed") === "true";
} catch (_error) {
  // Browsers may disable storage; the toggle still works for this page.
}

function syncSidebarVisibility() {
  if (!sidebar) return;
  const hidden = desktopSidebar.matches
    ? sidebarCollapsed
    : !sidebar.classList.contains("is-open");
  sidebar.inert = hidden;
  sidebar.setAttribute("aria-hidden", String(hidden));
}

function setSidebarCollapsed(collapsed) {
  sidebarCollapsed = collapsed;
  document.documentElement.classList.toggle("sidebar-collapsed", collapsed);
  if (sidebarToggle) {
    const label = collapsed ? "展开侧栏" : "折叠侧栏";
    sidebarToggle.setAttribute("aria-label", label);
    sidebarToggle.setAttribute("title", label);
    sidebarToggle.setAttribute("aria-expanded", String(!collapsed));
    const icon = sidebarToggle.querySelector("i");
    icon.classList.toggle("mdi-chevron-left", !collapsed);
    icon.classList.toggle("mdi-chevron-right", collapsed);
  }
  syncSidebarVisibility();
}

setSidebarCollapsed(sidebarCollapsed);
if (sidebarToggle) {
  sidebarToggle.addEventListener("click", () => {
    setSidebarCollapsed(!sidebarCollapsed);
    try {
      localStorage.setItem(
        "teslamate:sidebar-collapsed",
        String(sidebarCollapsed),
      );
    } catch (_error) {}
  });
}
desktopSidebar.addEventListener("change", () => setSidebar(false));

function setSidebar(open) {
  if (!sidebar || !sidebarBackdrop) return;
  sidebar.classList.toggle("is-open", open);
  sidebarBackdrop.classList.toggle("is-open", open);
  document.documentElement.classList.toggle("is-clipped", open);
  syncSidebarVisibility();
}

if (sidebarOpen) sidebarOpen.addEventListener("click", () => setSidebar(true));
if (sidebarClose)
  sidebarClose.addEventListener("click", () => setSidebar(false));
if (sidebarBackdrop)
  sidebarBackdrop.addEventListener("click", () => setSidebar(false));

// The root layout survives LiveView navigation, so update it when the URL changes.
function syncSidebarNavigation() {
  const path = window.location.pathname.replace(/\/+$/, "") || "/";

  document.querySelectorAll(".sidebar-nav a[href]").forEach((link) => {
    const target = new URL(link.href, window.location.href);
    const route = target.pathname.replace(/\/+$/, "") || "/";
    const active =
      target.origin === window.location.origin &&
      (path === route || (route !== "/" && path.startsWith(route + "/")));

    link.classList.toggle("is-active", active);
    if (active) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  });
}

syncSidebarNavigation();
window.addEventListener("phx:navigate", () => {
  syncSidebarNavigation();
  setSidebar(false);
});

for (const navDropdown of document.querySelectorAll(
  ".navbar-item.has-dropdown",
)) {
  navDropdown.addEventListener("click", function () {
    if (document.querySelector(".navbar-menu.is-active")) {
      this.classList.toggle("active");
    }
  });
}

// Open Statistics dashboard with the browser time zone
const statistics = document.querySelector("a[data-uid='1EZnXszMk']");
const tz = Intl && Intl.DateTimeFormat().resolvedOptions().timeZone;

if (statistics && tz)
  statistics.href = `${statistics.href}?var-timezone=${decodeURIComponent(tz)}`;

// Fix sticky hover on iOS
document.addEventListener("click", () => 0);

// Address dynamic viewport units on mobile
function setCustomVh() {
  let vh = window.innerHeight * 0.01;
  document.documentElement.style.setProperty("--vh", `${vh}px`);
}

window.addEventListener("resize", setCustomVh);
setCustomVh();

// Theme handling
function applyTheme() {
  const themeMode = document.documentElement.getAttribute("data-theme-mode");
  let actualTheme = themeMode;

  // If theme mode is "system", check system preference
  if (themeMode === "system") {
    actualTheme = window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "dark"
      : "light";
  }

  // Apply the theme
  document.documentElement.setAttribute("data-theme", actualTheme);

  // Trigger a custom event for components that need to react to theme changes
  window.dispatchEvent(
    new CustomEvent("themechange", { detail: { theme: actualTheme } }),
  );
}

// Apply theme on load
applyTheme();

// Listen for system theme changes when in system mode
if (window.matchMedia) {
  window
    .matchMedia("(prefers-color-scheme: dark)")
    .addEventListener("change", () => {
      const themeMode =
        document.documentElement.getAttribute("data-theme-mode");
      if (themeMode === "system") {
        applyTheme();
      }
    });
}
