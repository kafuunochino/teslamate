// Selection always refers to an actual sample, never an interpolated value.
export function nearestPoint(points, x) {
  return points.reduce(
    (nearest, point, index) =>
      Math.abs(point.x - x) < Math.abs(points[nearest].x - x) ? index : nearest,
    0,
  );
}

export const LineChart = {
  mounted() {
    this.renderChart();
  },

  updated() {
    this.renderChart();
  },

  destroyed() {
    this.removeChartListeners?.();
  },

  renderChart() {
    this.removeChartListeners?.();
    const points = JSON.parse(this.el.dataset.points || "[]");
    const plot = this.el.querySelector("[data-chart-plot]");
    if (!plot || !points.length) {
      this.chartTime = undefined;
      return;
    }

    const label = this.el.querySelector("[data-chart-label]");
    const value = this.el.querySelector("[data-chart-value]");
    const marker = this.el.querySelector("[data-chart-marker]");
    const guide = this.el.querySelector("[data-chart-guide]");
    const tooltip = this.el.querySelector("[data-chart-tooltip]");
    const tooltipLabel = this.el.querySelector("[data-tooltip-label]");
    const tooltipValue = this.el.querySelector("[data-tooltip-value]");
    let selected = points.findIndex((point) => point.time === this.chartTime);
    if (selected < 0 || this.chartFollowLatest) selected = points.length - 1;

    const select = (index, showTooltip = true) => {
      selected = Math.max(0, Math.min(points.length - 1, index));
      const point = points[selected];
      this.chartTime = point.time;
      this.chartFollowLatest = selected === points.length - 1;
      label.textContent = point.label;
      value.textContent = point.formatted;
      tooltipLabel.textContent = point.label;
      tooltipValue.textContent = point.formatted;
      marker.style.left = `${(point.x / 720) * 100}%`;
      marker.style.top = `${(point.y / 200) * 100}%`;
      guide.setAttribute("x1", point.x);
      guide.setAttribute("x2", point.x);
      tooltip.style.left = `clamp(78px, ${(point.x / 720) * 100}%, calc(100% - 78px))`;
      tooltip.hidden = !showTooltip;
    };
    const pointer = (event) => {
      // Let vertical touch gestures continue to scroll the page normally.
      if (
        event.type === "pointermove" &&
        event.pointerType === "touch" &&
        !event.buttons
      )
        return;
      const rect = plot.getBoundingClientRect();
      if (rect.width > 0)
        select(
          nearestPoint(
            points,
            ((event.clientX - rect.left) / rect.width) * 720,
          ),
        );
    };
    const hide = () => {
      tooltip.hidden = true;
    };
    const key = (event) => {
      const next = {
        ArrowLeft: selected - 1,
        ArrowRight: selected + 1,
        Home: 0,
        End: points.length - 1,
      }[event.key];
      if (next !== undefined) {
        event.preventDefault();
        select(next);
      } else if (event.key === "Escape") hide();
    };
    const events = {
      pointermove: pointer,
      pointerdown: pointer,
      pointerleave: hide,
      pointercancel: hide,
      keydown: key,
      blur: hide,
    };
    for (const [name, listener] of Object.entries(events))
      plot.addEventListener(name, listener);
    this.removeChartListeners = () => {
      for (const [name, listener] of Object.entries(events))
        plot.removeEventListener(name, listener);
    };
    select(selected, false);
  },
};
