const API_URL =
  "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
const RETRY_DELAYS = [2000, 5000];
const NETWORK_HELP =
  "无法连接 Cloudflare 验证服务。部分国内网络可能无法访问，请稍后重试或联系管理员。";

function challengeError(code) {
  const value = String(code || "");
  const suffix = /^\d{6}$/.test(value) ? `（错误码：${value}）` : "";
  if (["110100", "110110", "400020", "400070"].includes(value))
    return ["人机验证服务配置异常，请联系管理员。" + suffix, false];
  if (value === "110200")
    return ["当前网站域名未获验证服务授权，请联系管理员。" + suffix, false];
  if (value === "200100")
    return ["请检查设备日期和时间，再刷新页面重新验证。" + suffix, false];
  if (value === "110500")
    return ["当前浏览器不支持验证，请升级浏览器后重试。" + suffix, false];
  if (value.startsWith("300") || value.startsWith("600"))
    return ["人机验证未完成，请重试；持续失败时请联系管理员。" + suffix, true];
  return [NETWORK_HELP + suffix, true];
}

export function mountTurnstile(win, doc) {
  const root = doc.querySelector("[data-turnstile]");
  if (!root) return null;

  const form = root.closest("form");
  const submit = form.querySelector(".auth-submit");
  const host = root.querySelector("[data-turnstile-widget]");
  const status = root.querySelector("[data-turnstile-status]");
  const retry = root.querySelector("[data-turnstile-retry]");
  let widget;
  let valid = false;
  let submitting = false;
  let loading;
  let layout;
  let theme;
  let generation = 0;
  let retries = 0;
  let retryTimer;
  let watchdog;
  let slowTimer;

  const size = () => (host.clientWidth < 300 ? "compact" : "flexible");
  const color = () =>
    doc.documentElement.dataset.theme === "dark" ? "dark" : "light";

  function clearTimers() {
    win.clearTimeout(retryTimer);
    win.clearTimeout(watchdog);
    win.clearTimeout(slowTimer);
  }

  function removeWidget() {
    if (widget !== undefined) {
      win.turnstile.remove(widget);
      widget = undefined;
    }
  }

  function pending(message, retryable = false) {
    valid = false;
    submit.disabled = true;
    status.textContent = message;
    retry.hidden = !retryable;
  }

  function loadAPI() {
    if (typeof win.turnstile?.render === "function")
      return Promise.resolve(win.turnstile);
    if (loading) return loading;

    loading = new Promise((resolve, reject) => {
      let settled = false;
      const script = doc.createElement("script");
      script.src = API_URL;
      script.async = true;
      script.nonce = doc.querySelector("script[nonce]")?.nonce || "";
      script.dataset.cfasync = "false";
      const timer = win.setTimeout(fail, 45000);
      function fail() {
        if (settled) return;
        settled = true;
        win.clearTimeout(timer);
        script.onload = script.onerror = null;
        script.remove();
        loading = null;
        reject(new Error("Verification unavailable"));
      }
      script.onerror = fail;
      script.onload = () => {
        if (settled) return;
        if (typeof win.turnstile?.render !== "function") return fail();
        settled = true;
        win.clearTimeout(timer);
        script.onload = script.onerror = null;
        resolve(win.turnstile);
      };
      doc.head.appendChild(script);
    });
    return loading;
  }

  function failed(id, message, retryable = true) {
    if (id !== generation || submitting) return;
    generation++;
    clearTimers();
    removeWidget();
    if (retryable && retries < RETRY_DELAYS.length) {
      const delay = RETRY_DELAYS[retries++];
      pending(
        `${message} 正在自动重试（${retries}/${RETRY_DELAYS.length}）…`,
        true,
      );
      retryTimer = win.setTimeout(() => start(), delay);
    } else {
      pending(message, true);
    }
  }

  function watch(id, delay = 60000) {
    win.clearTimeout(watchdog);
    watchdog = win.setTimeout(() => failed(id, NETWORK_HELP), delay);
  }

  function render(id, api) {
    if (id !== generation) return;
    win.clearTimeout(slowTimer);
    pending("正在进行人机验证…");
    watch(id);
    const rendered = api.render(host, {
      sitekey: root.dataset.sitekey,
      action: root.dataset.action,
      theme,
      size: layout,
      language: "zh-cn",
      // Own the retry budget so an unreachable service cannot spin forever.
      retry: "never",
      "refresh-expired": "manual",
      callback: (token) => {
        if (id !== generation || submitting) return;
        if (typeof token !== "string" || token.length === 0)
          return failed(id, "未收到有效验证结果，请重新验证。");
        clearTimers();
        retries = 0;
        valid = true;
        submit.disabled = false;
        status.textContent = "人机验证已通过";
        retry.hidden = true;
      },
      "expired-callback": () => {
        if (id !== generation || submitting) return;
        generation++;
        clearTimers();
        removeWidget();
        pending("验证已过期，正在重新验证…");
        retryTimer = win.setTimeout(() => start(true), 0);
      },
      "timeout-callback": () => failed(id, "验证超时，请重新完成验证。"),
      "error-callback": (code) => {
        failed(id, ...challengeError(code));
        return true;
      },
      "before-interactive-callback": () => {
        if (id !== generation) return;
        pending("请完成上方的人机验证。", true);
        watch(id, 120000);
      },
      "unsupported-callback": () =>
        failed(id, "当前浏览器不支持验证，请升级浏览器后重试。", false),
    });
    // Some SDK errors fire synchronously inside render(). Discard that widget.
    if (id === generation) widget = rendered;
    else if (rendered !== undefined) api.remove(rendered);
  }

  async function start(resetRetries = false) {
    if (submitting) return;
    if (resetRetries) retries = 0;
    const id = ++generation;
    clearTimers();
    removeWidget();
    layout = size();
    theme = color();
    if (win.navigator?.onLine === false) {
      pending("网络已断开，连接恢复后会自动重新验证。", true);
      return;
    }
    pending("正在加载人机验证…");
    slowTimer = win.setTimeout(() => {
      if (id === generation)
        pending("连接验证服务较慢，请稍候；也可重新加载验证。", true);
    }, 15000);
    try {
      const api = await loadAPI();
      render(id, api);
    } catch (_error) {
      failed(id, NETWORK_HELP);
    }
  }

  submit.disabled = true;
  form.addEventListener("submit", (event) => {
    if (!valid || submitting) event.preventDefault();
    else {
      submitting = true;
      clearTimers();
      submit.disabled = true;
    }
  });
  if (root.dataset.configured !== "true") return null;

  retry.addEventListener("click", () => start(true));
  win.addEventListener("online", () => {
    if (!valid) start(true);
  });
  win.addEventListener("offline", () => {
    if (!valid)
      failed(generation, "网络已断开，连接恢复后会自动重新验证。", false);
  });
  win.addEventListener("themechange", () => {
    if (theme !== color()) start(true);
  });
  win.addEventListener("pageshow", (event) => {
    if (event.persisted) {
      submitting = false;
      start(true);
    }
  });
  if (win.ResizeObserver) {
    new win.ResizeObserver(() => {
      if (layout && layout !== size()) start(true);
    }).observe(host);
  }
  const ready = start();
  return { ready };
}
