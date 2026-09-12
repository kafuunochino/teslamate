const API_URL =
  "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";

export function mountTurnstile(win, doc) {
  const root = doc.querySelector("[data-turnstile]");
  if (!root) return null;

  const form = root.closest("form");
  const submit = form.querySelector(".auth-submit");
  const host = root.querySelector("[data-turnstile-widget]");
  const status = root.querySelector("[data-turnstile-status]");
  const retry = root.querySelector("button");
  let widget;
  let valid = false;
  let loading;
  let layout;

  function pending(message, retryable = false) {
    valid = false;
    submit.disabled = true;
    status.textContent = message;
    retry.hidden = !retryable;
  }

  function loadAPI() {
    if (win.turnstile) return Promise.resolve(win.turnstile);
    if (loading) return loading;

    loading = new Promise((resolve, reject) => {
      const script = doc.createElement("script");
      script.src = API_URL;
      script.async = true;
      script.nonce = doc.querySelector("script[nonce]")?.nonce || "";
      script.dataset.cfasync = "false";
      const timer = win.setTimeout(fail, 20000);
      function fail() {
        win.clearTimeout(timer);
        script.remove();
        loading = null;
        reject(new Error("Verification unavailable"));
      }
      script.onerror = fail;
      script.onload = () => {
        win.clearTimeout(timer);
        if (win.turnstile) resolve(win.turnstile);
        else fail();
      };
      doc.head.appendChild(script);
    });
    return loading;
  }

  function render() {
    if (!win.turnstile) return;
    pending("正在进行人机验证…");
    if (widget !== undefined) win.turnstile.remove(widget);
    layout = host.clientWidth < 300 ? "compact" : "flexible";
    widget = win.turnstile.render(host, {
      sitekey: root.dataset.sitekey,
      action: root.dataset.action,
      theme: doc.documentElement.dataset.theme === "dark" ? "dark" : "light",
      size: layout,
      language: "zh-cn",
      retry: "never",
      callback: () => {
        valid = true;
        submit.disabled = false;
        status.textContent = "人机验证已通过";
        retry.hidden = true;
      },
      "expired-callback": () => pending("验证已过期，请重新验证", true),
      "timeout-callback": () => pending("验证超时，请重试", true),
      "error-callback": () => {
        pending("人机验证加载失败，请检查网络后重试", true);
      },
      "unsupported-callback": () =>
        pending("当前浏览器不支持验证，请升级浏览器后重试"),
    });
  }

  async function start() {
    pending("正在加载人机验证…");
    try {
      await loadAPI();
      render();
    } catch (_error) {
      pending("人机验证加载失败，请检查网络后重试", true);
    }
  }

  submit.disabled = true;
  form.addEventListener("submit", (event) => {
    if (!valid) event.preventDefault();
    else submit.disabled = true;
  });
  if (root.dataset.configured !== "true") return null;

  retry.addEventListener("click", start);
  win.addEventListener("themechange", render);
  win.addEventListener("pageshow", (event) => {
    if (event.persisted) render();
  });
  if (win.ResizeObserver) {
    new win.ResizeObserver(() => {
      if (
        layout &&
        layout !== (host.clientWidth < 300 ? "compact" : "flexible")
      )
        render();
    }).observe(host);
  }
  const ready = start();
  return { ready };
}
