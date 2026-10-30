// The route of one feature: redraws the hero map for a risk level and a
// workflow profile. Without JavaScript the map shows medium risk under the
// standard profile, which is complete on its own.
(function () {
  "use strict";
  var root = document.getElementById("lifecycle");
  var form = root && root.querySelector(".switches");
  if (!form) return;

  function text(level, profile) {
    var bypass = level === "low" && profile === "light";
    return {
      impl: level === "high" ? "claude fable" : "claude opus",
      review: bypass ? "skipped" : "codex, read-only",
      triage: bypass ? "none" : (profile === "light" && level !== "high" ? "light triage" : "full triage"),
      merge: "by you",
      caption: bypass
        ? "<strong>Low risk, light profile.</strong> Documentation and process files skip the review. The commit records that it was not reviewed, and the merge waits for your approval."
        : level === "high"
          ? "<strong>High risk.</strong> The stronger model implements, the full triage applies, and no profile can remove the review or lower the level."
          : level === "low"
            ? "<strong>Low risk, standard profile.</strong> Still reviewed by another provider. As shipped there is no low class; a project adds one in risk.conf."
            : profile === "light"
              ? "<strong>Medium risk, light profile.</strong> Reviewed; minor findings and suggestions can be accepted or deferred without another fix round."
              : "<strong>Medium risk.</strong> Claude implements and Codex reviews, so the reviewer always comes from another provider, and the merge stays with you."
    };
  }

  function apply() {
    var level = form.risk.value, profile = form.profile.value;
    root.dataset.risk = level;
    root.dataset.profile = profile;
    var t = text(level, profile);
    root.querySelectorAll("[data-k]").forEach(function (el) {
      var k = el.getAttribute("data-k");
      if (k === "caption") el.innerHTML = t.caption; else el.textContent = t[k];
    });
    root.querySelectorAll(".r-word").forEach(function (li) { li.hidden = level === "low" && profile === "light"; });
  }
  form.addEventListener("change", apply);

  var btn = document.querySelector(".theme");
  if (btn) {
    var label = btn.querySelector("span");
    var current = function () {
      var set = document.documentElement.dataset.theme;
      return set || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    };
    var show = function () { label.textContent = current() === "dark" ? "Light" : "Dark"; };
    show();
    btn.addEventListener("click", function () {
      var next = current() === "dark" ? "light" : "dark";
      document.documentElement.dataset.theme = next;
      try { localStorage.setItem("act-theme", next); } catch (e) {}
      show();
    });
  }
})();
