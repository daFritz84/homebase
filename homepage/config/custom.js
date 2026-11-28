// Time-of-day greeting for the greeting info widget (widgets.yaml).
// Served at /api/config/custom.js (index.jsx <Script>).
// DOM contract verified against gethomepage/homepage v2.8.0
// src/components/widgets/greeting/greeting.jsx:
//   .information-widget-greeting > span  (the greeting is the only widget
//   with that class). Re-verify after any Homepage version bump.
(function () {
  "use strict";

  var PLACEHOLDER = "Good day";
  var GREETINGS = /^Good (morning|afternoon|evening|night)$/;

  function greeting() {
    var h = new Date().getHours();
    if (h < 5) return "Good night";
    if (h < 12) return "Good morning";
    if (h < 18) return "Good afternoon";
    return "Good evening";
  }

  function swap() {
    var span = document.querySelector(".information-widget-greeting span");
    if (!span) return;
    var current = span.textContent.trim();
    // Only touch the placeholder or a greeting we set — never user text.
    if (current !== PLACEHOLDER && !GREETINGS.test(current)) return;
    var next = greeting();
    if (current !== next) span.textContent = next;
  }

  function start() {
    swap();
    // Survive Homepage's client-side re-renders (SWR refetches remount the
    // widget); the guard above makes repeat runs idempotent.
    new MutationObserver(swap).observe(document.body, {
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
