import { mountTurnstile } from "./turnstile.mjs";

const SDK = {
  aliyun:
    "https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js",
  tencent: "https://turing.captcha.qcloud.com/TJCaptcha.js",
};

export function mountCaptcha(win, doc) {
  const root = doc.querySelector("[data-captcha]");
  if (!root) return mountTurnstile(win, doc);

  const provider = root.dataset.provider;
  const form = root.closest("form");
  const submit = form.querySelector(".auth-submit");
  const status = root.querySelector("[data-captcha-status]");
  const retry = root.querySelector("[data-captcha-retry]");
  const tokenInput = root.querySelector("[data-captcha-token]");
  const randInput = root.querySelector("[data-captcha-randstr]");
  let trigger = root.querySelector("[data-captcha-trigger]");
  let instance;
  let generation = 0;
  let valid = false;
  let submitting = false;
  let loading;
  let timer;

  function clear(message, retryable = false) {
    valid = false;
    tokenInput.value = randInput.value = "";
    submit.disabled = true;
    status.textContent = message;
    retry.hidden = !retryable;
    win.clearTimeout(timer);
  }

  function close() {
    try {
      if (provider === "tencent") instance?.destroy();
      else instance?.hide();
    } catch (_error) {
      // A partially loaded SDK may not have a usable instance yet.
    }
    instance = undefined;
  }

  function failed(id, message) {
    if (id !== generation || submitting) return;
    generation++;
    close();
    trigger.disabled = true;
    clear(message, true);
  }

  function accepted(id, token, randstr = "") {
    if (id !== generation || submitting) return;
    if (
      typeof token !== "string" ||
      !token ||
      token.length > 32768 ||
      (provider === "tencent" &&
        (token.startsWith("trerror_") ||
          typeof randstr !== "string" ||
          !randstr))
    ) {
      failed(id, "未收到有效验证结果，请重新加载验证。");
      return;
    }
    win.clearTimeout(timer);
    tokenInput.value = token;
    randInput.value = randstr;
    valid = true;
    submit.disabled = false;
    trigger.disabled = true;
    retry.hidden = true;
    status.textContent = "已完成验证，请继续提交。";
    // The server is authoritative. Never interpret an SDK callback as server approval.
    timer = win.setTimeout(
      () => failed(id, "验证已过期，请重新加载验证。"),
      provider === "aliyun" ? 75000 : 240000,
    );
  }

  const available = () =>
    typeof (provider === "aliyun"
      ? win.initAliyunCaptcha
      : win.TencentCaptcha) === "function";

  function load() {
    if (available()) return Promise.resolve();
    if (loading) return loading;
    loading = new Promise((resolve, reject) => {
      const script = doc.createElement("script");
      script.src = SDK[provider];
      script.async = true;
      script.nonce = doc.querySelector("script[nonce]")?.nonce || "";
      script.dataset.cfasync = "false";
      let done = false;
      const timeout = win.setTimeout(() => finish(false), 20000);
      function finish(ok) {
        if (done) return;
        done = true;
        win.clearTimeout(timeout);
        script.onload = script.onerror = null;
        if (ok) resolve();
        else {
          script.remove();
          loading = undefined;
          reject(new Error("CAPTCHA unavailable"));
        }
      }
      script.onload = () => finish(available());
      script.onerror = () => finish(false);
      doc.head.appendChild(script);
    });
    return loading;
  }

  async function start() {
    if (submitting) return;
    const id = ++generation;
    close();
    clear("正在加载人机验证…");
    // Remove old SDK button handlers when reinitializing an expired challenge.
    const button = trigger.cloneNode(true);
    trigger.replaceWith(button);
    trigger = button;
    trigger.disabled = true;
    if (win.navigator?.onLine === false) {
      failed(id, "网络已断开，连接恢复后可重新验证。");
      return;
    }
    if (provider === "aliyun") {
      win.AliyunCaptchaConfig = {
        region: root.dataset.region,
        prefix: root.dataset.prefix,
      };
    }
    try {
      await load();
      if (id !== generation) return;
      status.textContent = "点击按钮完成人机验证。";
      if (provider === "tencent") {
        const created = new win.TencentCaptcha(
          root.dataset.appId,
          (result) => {
            if (id !== generation || submitting) return;
            win.clearTimeout(timer);
            if (result?.ret === 0 && !result.errorCode)
              accepted(id, result.ticket, result.randstr);
            else if (result?.ret === 2) clear("验证已取消，点击按钮可重试。");
            else failed(id, "验证未完成，请重新加载验证。");
          },
          { userLanguage: "zh-cn" },
        );
        if (id !== generation) {
          created.destroy();
          return;
        }
        instance = created;
        trigger.disabled = false;
        trigger.addEventListener("click", () => {
          if (id !== generation) return;
          status.textContent = "请完成弹窗中的验证。";
          trigger.disabled = true;
          win.clearTimeout(timer);
          timer = win.setTimeout(
            () => failed(id, "验证超时，请重新加载验证。"),
            120000,
          );
          try {
            instance.show();
          } catch (_error) {
            failed(id, "验证加载失败，请重新加载验证。");
          }
        });
      } else {
        timer = win.setTimeout(
          () => failed(id, "验证加载超时，请重新加载验证。"),
          20000,
        );
        win.initAliyunCaptcha({
          SceneId: root.dataset.scene,
          mode: "popup",
          element: "#captcha-widget",
          button: "#captcha-trigger",
          language: "cn",
          slideStyle: { width: 320, height: 40 },
          rem: Math.min(1, Math.max(0.5, (win.innerWidth - 32) / 320)),
          success: (token) => accepted(id, token),
          fail: () => failed(id, "验证未通过，请重新加载验证。"),
          onError: () => failed(id, "验证加载失败，请检查厂商配置或稍后重试。"),
          getInstance: (captcha) => {
            if (id !== generation) {
              captcha?.hide();
              return;
            }
            win.clearTimeout(timer);
            instance = captcha;
            trigger.disabled = false;
          },
        });
        trigger.addEventListener("click", () => {
          if (id !== generation) return;
          win.clearTimeout(timer);
          timer = win.setTimeout(
            () => failed(id, "验证超时，请重新加载验证。"),
            120000,
          );
        });
      }
    } catch (_error) {
      failed(id, "人机验证加载失败，请检查网络或联系管理员检查厂商配置。");
    }
  }

  clear("正在加载人机验证…");
  form.addEventListener("submit", (event) => {
    if (!valid || submitting) event.preventDefault();
    else {
      submitting = true;
      submit.disabled = true;
      win.clearTimeout(timer);
    }
  });
  if (root.dataset.configured !== "true" || !SDK[provider]) {
    clear("人机验证尚未配置完整，请联系管理员。");
    return null;
  }
  retry.addEventListener("click", start);
  win.addEventListener("pageshow", (event) => {
    if (event.persisted) {
      submitting = false;
      start();
    }
  });
  win.addEventListener("offline", () => {
    if (!submitting) failed(generation, "网络已断开，连接恢复后可重新验证。");
  });
  win.addEventListener("online", () => {
    if (!valid) start();
  });
  return { ready: start() };
}
