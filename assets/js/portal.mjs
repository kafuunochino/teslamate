// The portal uses static, fictional examples. It never fetches vehicle APIs.
export function mountPortal(win, doc) {
  const story = doc.querySelector(".portal-story");
  if (!story) return;
  mountPreviews(win, doc);
  const scenes = [...story.querySelectorAll(".portal-scene")];
  const chapters = [...doc.querySelectorAll(".portal-chapters a")];
  const motion = win.matchMedia("(prefers-reduced-motion: reduce)");
  const syncMotion = () =>
    doc.body.classList.toggle("portal-motion", !motion.matches);
  syncMotion();
  motion.addEventListener?.("change", syncMotion);
  let scheduled = false;
  const update = () => {
    scheduled = false;
    const top = story.getBoundingClientRect().top;
    const middle = top + story.clientHeight * 0.5;
    let active = 0;
    scenes.forEach((scene, index) => {
      const rect = scene.getBoundingClientRect();
      const visible =
        rect.top < top + story.clientHeight * 0.82 && rect.bottom > top + 100;
      scene.classList.toggle("is-visible", visible);
      if (rect.top <= middle) active = index;
    });
    chapters.forEach((link, index) => {
      if (index === active) link.setAttribute("aria-current", "location");
      else link.removeAttribute("aria-current");
    });
    doc.body.style.setProperty(
      "--portal-progress",
      String((active + 1) / scenes.length),
    );
    const travel = motion.matches ? 0 : Math.min(story.scrollTop * 0.08, 30);
    doc.body.style.setProperty("--portal-travel", `${travel}px`);
  };
  const schedule = () => {
    if (scheduled) return;
    scheduled = true;
    win.requestAnimationFrame(update);
  };
  story.addEventListener("scroll", schedule, { passive: true });
  win.addEventListener("resize", schedule, { passive: true });
  // Native scrolling is retained: no wheel interception or keyboard trap.
  doc.querySelectorAll('a[href^="#"]').forEach((link) => {
    const target = doc.getElementById(link.getAttribute("href").slice(1));
    if (!target || !story.contains(target)) return;
    link.addEventListener("click", (event) => {
      event.preventDefault();
      target.scrollIntoView({
        behavior: motion.matches ? "auto" : "smooth",
        block: "start",
      });
      win.history.replaceState(null, "", link.getAttribute("href"));
      // Preserve keyboard reading order after a chapter link is used.
      target.setAttribute("tabindex", "-1");
      target.focus({ preventScroll: true });
    });
  });
  update();
}

function mountPreviews(win, doc) {
  const dialog = doc.getElementById("portal-preview-dialog");
  const expanded = dialog?.querySelector(".portal-preview-expanded");
  const stages = [...doc.querySelectorAll(".portal-preview-stage")];
  const syncTheme = (frame) => {
    const root = frame.contentDocument?.documentElement;
    if (root) {
      root.dataset.theme = doc.documentElement.dataset.theme || "light";
      win.teslamateTheme?.syncControls(frame.contentDocument);
    }
  };
  const fitExpanded = () => {
    const frame = expanded?.querySelector("iframe");
    if (!frame?.contentDocument?.body) return;
    frame.style.height = "1px";
    frame.style.height = `${Math.max(500, frame.contentDocument.documentElement.scrollHeight)}px`;
  };
  const resize = () => {
    stages.forEach((stage) =>
      stage.style.setProperty(
        "--preview-scale",
        String(stage.clientWidth / 1440),
      ),
    );
    fitExpanded();
  };
  stages.forEach((stage) => {
    const frame = stage.querySelector("iframe");
    frame.addEventListener("load", () => syncTheme(frame));
    syncTheme(frame);
  });
  win.addEventListener("themechange", () => {
    doc.querySelectorAll(".portal-preview-screen").forEach(syncTheme);
  });
  win.addEventListener("resize", resize, { passive: true });
  if (win.ResizeObserver) {
    const observer = new win.ResizeObserver(() => {
      stages.forEach((stage) =>
        stage.style.setProperty(
          "--preview-scale",
          String(stage.clientWidth / 1440),
        ),
      );
    });
    stages.forEach((stage) => observer.observe(stage));
  }
  doc.querySelectorAll("[data-preview-page]").forEach((button) => {
    button.addEventListener("click", () => {
      if (!dialog || !expanded) return;
      const source = button.closest("figure").querySelector("iframe");
      const frame = source.cloneNode();
      frame.removeAttribute("loading");
      frame.classList.add("is-expanded");
      frame.addEventListener("load", () => {
        syncTheme(frame);
        fitExpanded();
        expanded.scrollTop = 0;
      });
      expanded.replaceChildren(frame);
      doc.getElementById("portal-preview-title").textContent =
        button.dataset.previewTitle;
      dialog.showModal();
      expanded.scrollTop = 0;
      fitExpanded();
    });
  });
  dialog
    ?.querySelector("[data-preview-close]")
    .addEventListener("click", () => dialog.close());
  dialog?.addEventListener("close", () => expanded.replaceChildren());
  resize();
}

export function mountInvitationCopy(win, doc) {
  doc.addEventListener("click", async (event) => {
    const button = event.target.closest?.("[data-copy-invitations]");
    if (!button) return;
    const field = doc.getElementById("invitation-codes");
    if (!field) return;
    try {
      await win.navigator.clipboard.writeText(field.value);
      button.textContent = "已复制";
    } catch (_error) {
      field.focus();
      field.select();
      button.textContent = "已选中，请手动复制";
    }
  });
}
