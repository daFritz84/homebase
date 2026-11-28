// Header widget placement: Homepage right-aligns only its built-in widget
// types (index.jsx rightAlignedWidgets) — the customapi forecast widget is
// left-aligned, so move it into the right corner, left of the weather.
// DOM contract verified against gethomepage/homepage v2.8.0:
//   .information-widget-customapi  src/components/widgets/customapi/customapi.jsx
//   #information-widgets-right     src/pages/index.jsx (Home)
// Re-verify after any Homepage version bump.
(function () {
  "use strict";

  var FORECAST = ".information-widget-customapi";
  var TARGET = "#information-widgets-right";

  function move() {
    var w = document.querySelector(FORECAST);
    var t = document.querySelector(TARGET);
    if (!w || !t) return;
    // Idempotent: already first in the right corner -> nothing to do.
    if (w.parentElement === t && t.firstElementChild === w) return;
    t.insertBefore(w, t.firstChild);
  }

  function start() {
    move();
    // Survive Homepage's client-side re-renders (SWR refetches remount the
    // widgets); the guard above makes repeat runs idempotent.
    new MutationObserver(move).observe(document.body, {
      childList: true,
      subtree: true,
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
