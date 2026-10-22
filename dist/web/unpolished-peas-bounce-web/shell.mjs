// Optional presentation for generated pages. Custom embeds keep their own UI.
export function createBrowserShell(canvas, documentRef = globalThis.document, locationRef = globalThis.location) {
  if (!canvas?.hasAttribute("data-peas-shell")) return {ready() {}, failed() {}};

  documentRef.documentElement.lang ||= "en";
  documentRef.body.classList.add("peas-page");
  const style = documentRef.createElement("style");
  style.textContent = `
    .peas-page { margin: 0; background: #111810; color: #eef4e9; font: 16px/1.5 system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
    .peas-shell { box-sizing: border-box; width: min(100%, 720px); margin: 0 auto; padding: clamp(16px, 4vw, 40px); }
    .peas-shell h1 { margin: 0 0 8px; font-size: clamp(24px, 5vw, 36px); line-height: 1.2; text-wrap: balance; }
    .peas-shell p { text-wrap: pretty; }
    .peas-shell canvas { display: block; width: 100%; height: auto; margin: 24px 0; background: #080d08; image-rendering: pixelated; outline: 1px solid rgb(255 255 255 / .15); }
    .peas-shell :focus-visible { outline: 3px solid #b7e78b; outline-offset: 4px; }
    .peas-shell .peas-help { color: #b8c6b0; }
    .peas-shell [role=status] { min-height: 1.5em; }
    .peas-shell [data-state=failed] { color: #ffd1b8; }
    .peas-actions { display: flex; flex-wrap: wrap; gap: 12px; }
    .peas-shell button { min-height: 44px; padding: 10px 18px; border: 0; border-radius: 6px; background: #b7e78b; color: #15200e; font: inherit; font-weight: 600; cursor: pointer; }
    .peas-shell button:hover { background: #c9efa8; }
    .peas-shell button:active { background: #a2d374; }
    .peas-shell [hidden] { display: none; }
  `;
  documentRef.head.append(style);

  const main = documentRef.createElement("main");
  main.className = "peas-shell";
  const title = documentRef.createElement("h1");
  title.textContent = documentRef.title || "Peas game";
  const help = documentRef.createElement("p");
  help.id = "peas-help";
  help.className = "peas-help";
  help.textContent = "Focus the game to use its keyboard controls. Tab moves out of the game. Sound starts after a click or key press.";
  const status = documentRef.createElement("p");
  status.setAttribute("role", "status");
  status.setAttribute("aria-live", "polite");
  status.textContent = "Loading game…";
  status.dataset.state = "loading";
  const actions = documentRef.createElement("div");
  actions.className = "peas-actions";
  function button(label, action) {
    const element = documentRef.createElement("button");
    element.type = "button";
    element.textContent = label;
    element.hidden = true;
    element.addEventListener("click", action);
    actions.append(element);
    return element;
  }
  const focus = button("Focus game", () => canvas.focus({preventScroll: true}));
  const retry = button("Reload game", () => locationRef.reload());
  const fallback = button("Try WebGL 2", () => {
    const url = new URL(locationRef.href);
    url.searchParams.set("renderer", "webgl2");
    locationRef.assign(url.href);
  });
  canvas.setAttribute("aria-label", `${title.textContent} game canvas`);
  canvas.setAttribute("aria-describedby", help.id);
  canvas.setAttribute("aria-busy", "true");
  canvas.before(main);
  main.append(title, help, canvas, status, actions);

  return {
    ready() {
      status.dataset.state = "ready";
      status.textContent = "Ready to play.";
      canvas.setAttribute("aria-busy", "false");
      focus.hidden = false;
      retry.hidden = fallback.hidden = true;
    },
    failed(diagnostic) {
      status.dataset.state = "failed";
      status.textContent = diagnostic.context_status === "device_lost"
        ? "The graphics device was disconnected. Reload the game to continue."
        : `The game could not start. ${diagnostic.recovery_instruction ?? "Reload the game to try again."}`;
      canvas.setAttribute("aria-busy", "false");
      focus.hidden = true;
      retry.hidden = false;
      fallback.hidden = diagnostic.requested_renderer === "webgl2";
    },
  };
}
