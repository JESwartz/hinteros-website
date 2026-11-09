// Copy buttons on the download page, the click-to-start launcher demo on the Demo page, and
// on the home page the Features and Tour carousels, the Technical stack building and the
// Features band's lines.

for (const button of document.querySelectorAll("button[data-copy]")) {
  button.addEventListener("click", async () => {
    const text = document.getElementById(button.dataset.copy).textContent.trim();
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Select and copy";
    }
    setTimeout(() => { button.textContent = "Copy"; }, 2000);
  });
}

const start = document.getElementById("demo-start");
if (start) {
  const player = document.getElementById("player");
  const home = document.getElementById("demo-home");
  const fullscreen = document.getElementById("demo-fullscreen");
  const padToggle = document.getElementById("demo-pad");
  const pad = document.getElementById("touch-pad");
  let frame;

  // The demo is same-origin, so keys are sent straight to the launcher's view. The event must be
  // made by the demo's own window: the launcher ignores a KeyboardEvent from this page.
  const view = () => frame.contentDocument.querySelector("flutter-view");
  const send = (type, key, code, repeat = false) => {
    view()?.dispatchEvent(new frame.contentWindow.KeyboardEvent(type, {
      key, code, repeat, bubbles: true, cancelable: true, composed: true,
    }));
  };
  // A click on a button of this page takes the focus from the launcher's view, and the keyboard
  // then does nothing in the demo. Give it back.
  const focusDemo = () => { frame.focus(); view()?.focus(); };

  // The demo is several MB, so it loads only when asked for.
  start.addEventListener("click", () => {
    frame = document.createElement("iframe");
    frame.src = "/demo/";
    frame.title = "HinterOS launcher demo";
    frame.allow = "fullscreen; gamepad";
    frame.addEventListener("load", () => frame.focus());
    start.replaceWith(frame);
    frame.focus();
    home.disabled = false;
    fullscreen.disabled = !player.requestFullscreen;
    padToggle.hidden = false;
    // Shown at the start on touch screens, where there is no other way to operate the demo.
    showPad(matchMedia("(pointer: coarse)").matches);
  });

  // The launcher takes the Home key as the controller's Guide button.
  home.addEventListener("click", () => {
    send("keydown", "Home", "Home");
    send("keyup", "Home", "Home");
    focusDemo();
  });

  const showPad = (on) => {
    pad.hidden = !on;
    padToggle.setAttribute("aria-pressed", on);
  };
  padToggle.addEventListener("click", () => { showPad(pad.hidden); focusDemo(); });

  // The on-screen controller sends the keyboard keys of the buttons. A held button repeats, as
  // a held key does. Each button follows its own pointer, so two fingers can hold two buttons.
  for (const button of pad.querySelectorAll("button")) {
    const key = button.dataset.key;
    const code = button.dataset.code || key;
    let timer;
    const release = () => {
      if (!button.classList.contains("on")) return;
      clearTimeout(timer);
      button.classList.remove("on");
      send("keyup", key, code);
    };
    button.addEventListener("pointerdown", (event) => {
      event.preventDefault(); // keeps the focus in the demo
      button.setPointerCapture(event.pointerId);
      button.classList.add("on");
      send("keydown", key, code);
      const repeat = () => { send("keydown", key, code, true); timer = setTimeout(repeat, 100); };
      timer = setTimeout(repeat, 400);
    });
    button.addEventListener("pointerup", release);
    button.addEventListener("pointercancel", release);
    button.addEventListener("lostpointercapture", release);
    button.addEventListener("contextmenu", (event) => event.preventDefault());
  }

  fullscreen.addEventListener("click", () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else player.requestFullscreen().then(focusDemo, () => {});
  });
  document.addEventListener("fullscreenchange", () => {
    fullscreen.textContent = document.fullscreenElement ? "Exit full screen" : "Full screen";
    if (frame) focusDemo();
  });
}

// The Tour carousel: the tabs and buttons scroll the track sideways only, and the tab of the
// slide in view is marked.
const track = document.querySelector(".tour-track");
if (track) {
  const slides = [...track.children];
  const tabs = [...document.querySelectorAll(".tour-tabs a")];
  const step = document.querySelector(".tour-step");
  let current = 0;
  const go = (k) => track.scrollTo({ left: slides[(k + slides.length) % slides.length].offsetLeft });
  const bar = document.querySelector(".tour-tabs");
  const mark = () => {
    const pitch = slides[1].offsetLeft - slides[0].offsetLeft;
    current = Math.round(track.scrollLeft / pitch);
    tabs.forEach((tab, k) => tab.setAttribute("aria-current", k === current));
    bar.style.setProperty("--screen", track.scrollLeft / pitch);
  };
  // Show only the current name when the names do not all fit on one line.
  let width = 0;
  const fit = () => {
    if (bar.clientWidth === width) return;
    width = bar.clientWidth;
    bar.classList.remove("compact");
    // The buttons are taller than the names, so compare with the bottom of the first name.
    const line = tabs[0].offsetTop + tabs[0].offsetHeight;
    bar.classList.toggle("compact", [...tabs, step].some((el) => el.offsetTop >= line));
  };
  new ResizeObserver(fit).observe(bar);
  document.fonts.ready.then(() => { width = 0; fit(); });
  tabs.forEach((tab, k) => tab.addEventListener("click", (event) => { event.preventDefault(); go(k); }));
  for (const button of step.querySelectorAll("button")) {
    button.addEventListener("click", () => go(current + Number(button.dataset.step)));
  }
  track.addEventListener("scroll", mark, { passive: true });
  step.hidden = false;
  bar.style.setProperty("--screens", slides.length);
  mark();
  fit();
}

// The Features carousel on narrow screens: the buttons scroll one card sideways. On wider
// screens the cards are a grid and the buttons are hidden by the style sheet.
const cards = document.querySelector(".features .grid");
if (cards) {
  const step = document.querySelector(".feature-step");
  const items = [...cards.children];
  for (const button of step.querySelectorAll("button")) {
    button.addEventListener("click", () => {
      const pitch = items[1].offsetLeft - items[0].offsetLeft;
      const k = Math.round(cards.scrollLeft / pitch) + Number(button.dataset.step);
      cards.scrollTo({ left: items[(k + items.length) % items.length].offsetLeft - items[0].offsetLeft });
    });
  }
  step.hidden = false;
}

// The Technical stack building: the floors (SVG groups) are tabs. Hover, focus or a click picks a floor, and
// the up and down arrow keys move between floors.
const stack = document.querySelector(".stack");
if (stack) {
  const floors = [...stack.querySelectorAll(".floor")];
  const building = stack.querySelector(".building");
  building.setAttribute("role", "tablist");
  building.setAttribute("aria-orientation", "vertical");
  const pick = (floor) => {
    for (const f of floors) {
      const on = f === floor;
      f.setAttribute("aria-selected", on);
      f.tabIndex = on ? 0 : -1;
      document.getElementById(f.getAttribute("aria-controls")).classList.toggle("on", on);
    }
  };
  for (const [k, floor] of floors.entries()) {
    floor.setAttribute("role", "tab");
    document.getElementById(floor.getAttribute("aria-controls")).setAttribute("role", "tabpanel");
    floor.addEventListener("mouseenter", () => pick(floor));
    floor.addEventListener("focus", () => pick(floor));
    floor.addEventListener("click", () => pick(floor));
    floor.addEventListener("keydown", (event) => {
      // The floors are drawn bottom up, so up is the next floor in the list.
      const move = { ArrowUp: 1, ArrowDown: -1 }[event.key];
      if (!move) return;
      event.preventDefault();
      floors[(k + move + floors.length) % floors.length].focus();
    });
  }
  stack.classList.add("live");
  pick(floors[0]);
}

// The home page's Features band: a web of lines, hexagons at the top left, triangles in the
// middle and squares at the bottom right. The hexagon region is the corner above the line from
// the band's top middle to its bottom-left corner; the square region is the corner below the
// line from its top-right corner to its bottom middle. It is drawn to the band's own size so
// those lines meet the corners.
//
// It is one triangle lattice, so the regions share their points and edges: hexagons are the
// lattice without every third point, and squares are the lattice without one diagonal of each
// pair of triangles and without the half-cell shift of every other row. All rows have the same
// height, between a triangle's and a square's, so the rows stay straight.
const band = document.querySelector(".features");
if (band) {
  const CELL = 46;
  const ROW = CELL * 0.933;
  const mod = (a, n) => ((a % n) + n) % n;
  const smooth = (a, b, v) => {
    const t = Math.min(1, Math.max(0, (v - a) / (b - a)));
    return t * t * (3 - 2 * t);
  };

  const draw = () => {
    const w = band.clientWidth;
    const h = band.clientHeight;
    // 0 at the top left, 1 on the hexagon line, 2 on the square line, 3 at the bottom right.
    const u = (x, y) => (2 * x) / w + y / h;
    const seam = 0.8 * CELL * Math.hypot(2 / w, 1 / h); // the shift fades over about a cell
    const pts = new Map();
    const key = (i, j) => `${i},${j}`;
    for (let j = -1; j <= Math.ceil(h / ROW) + 1; j++) {
      const shift = mod(j, 2) / 2;
      for (let i = -1; i <= Math.ceil(w / CELL) + 1; i++) {
        const x0 = (i + shift) * CELL;
        const y = j * ROW;
        const t = smooth(2 - seam, 2 + seam, u(x0, y));
        const centre = mod(i - Math.floor(j / 2) - j, 3) === 0 && u(x0, y) < 1;
        pts.set(key(i, j), { x: (i + shift * (1 - t)) * CELL, y, t, centre });
      }
    }
    let d = "";
    const line = (a, b) => { d += `M${a.x.toFixed(1)} ${a.y.toFixed(1)}L${b.x.toFixed(1)} ${b.y.toFixed(1)}`; };
    for (const [k, p] of pts) {
      if (p.centre) continue;
      const [i, j] = k.split(",").map(Number);
      const right = pts.get(key(i + 1, j));
      const below = pts.get(key(i, j + 1));
      const slant = pts.get(key(mod(j, 2) ? i + 1 : i - 1, j + 1));
      if (right && !right.centre) line(p, right);
      if (below && !below.centre) line(p, below);
      if (slant && !slant.centre && Math.max(p.t, slant.t) < 0.5) line(p, slant);
    }
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}">` +
      `<path fill="none" stroke="#232b40" stroke-width="1.5" stroke-linecap="round" d="${d}"/></svg>`;
    band.style.backgroundImage = `url("data:image/svg+xml,${encodeURIComponent(svg)}")`;
  };

  let size = "";
  new ResizeObserver(() => {
    const now = `${band.clientWidth}x${band.clientHeight}`;
    if (now !== size) { size = now; draw(); }
  }).observe(band);
}
