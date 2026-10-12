// The documentation site of the template. Everything on a page reads without
// this script; it adds the menu on a narrow screen, the theme switch, a copy
// button on commands, and the dialog that shows a diagram or the details of a
// step. A page marks the
// document with the class js in its head, so that the style sheet folds the
// navigation behind the menu button only when this script can open it.

(function () {
  "use strict";

  // --- Theme: follow the system until the reader chooses ---------------------

  var root = document.documentElement;
  var stored = null;
  try {
    stored = localStorage.getItem("theme");
  } catch (error) {
    stored = null;
  }
  if (stored === "light" || stored === "dark") {
    root.setAttribute("data-theme", stored);
  }

  function currentTheme() {
    var chosen = root.getAttribute("data-theme");
    if (chosen) {
      return chosen;
    }
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  var toggle = document.querySelector(".theme-toggle");
  if (toggle) {
    toggle.hidden = false;
    var label = function () {
      toggle.textContent = currentTheme() === "dark" ? "Light theme" : "Dark theme";
    };
    label();
    toggle.addEventListener("click", function () {
      var next = currentTheme() === "dark" ? "light" : "dark";
      root.setAttribute("data-theme", next);
      try {
        localStorage.setItem("theme", next);
      } catch (error) {
        // The choice then lasts for this page only.
      }
      label();
    });
  }

  // --- Menu on a narrow screen ------------------------------------------------

  var menu = document.querySelector(".menu-button");
  if (menu) {
    menu.addEventListener("click", function () {
      var open = document.body.classList.toggle("menu-open");
      menu.setAttribute("aria-expanded", open ? "true" : "false");
    });
    document.addEventListener("click", function (event) {
      if (!event.target.closest(".sidebar") && !event.target.closest(".menu-button")) {
        document.body.classList.remove("menu-open");
        menu.setAttribute("aria-expanded", "false");
      }
    });
  }

  // --- Copy a command ---------------------------------------------------------

  if (navigator.clipboard && navigator.clipboard.writeText) {
    Array.prototype.forEach.call(document.querySelectorAll("pre"), function (block) {
      var code = block.querySelector("code");
      if (!code) {
        return;
      }
      var button = document.createElement("button");
      button.type = "button";
      button.className = "copy-button";
      button.textContent = "Copy";
      button.addEventListener("click", function () {
        navigator.clipboard.writeText(code.textContent).then(function () {
          button.textContent = "Copied";
          setTimeout(function () {
            button.textContent = "Copy";
          }, 1600);
        });
      });
      block.appendChild(button);
    });
  }

  // --- A diagram or the details of a step, in a dialog -----------------------
  //
  // A link with the class step or popup-link that points to a place on the
  // page opens that place in a dialog: a lane (a diagram of its own) or the
  // details of one step. A link inside the dialog opens the next level, and
  // "Back" returns to the diagram it came from.

  var selector = "a.step[href^='#'], a.popup-link[href^='#']";
  if (!document.querySelector(selector) || typeof HTMLDialogElement === "undefined") {
    return;
  }

  // The steps of a stage, in order. A panel that is not a step of a stage
  // (updating the plan, the unattended run) has the class extra.
  function stepsOf(target) {
    if (!target.parentNode || target.classList.contains("extra")) {
      return [];
    }
    return Array.prototype.slice.call(target.parentNode.querySelectorAll(".detail[id]:not(.extra)"));
  }
  var dialog = document.createElement("dialog");
  dialog.className = "popup";
  dialog.innerHTML =
    '<p class="popup-where" hidden></p>' +
    '<div class="popup-body"></div>' +
    '<div class="popup-bar">' +
    '<span><button type="button" data-back>← Back to the diagram</button> ' +
    '<button type="button" data-go="-1">← Previous</button> ' +
    '<button type="button" data-go="1">Next →</button></span>' +
    '<button type="button" data-close>Close</button>' +
    "</div>";
  document.body.appendChild(dialog);

  var body = dialog.querySelector(".popup-body");
  var where = dialog.querySelector(".popup-where");
  var back = dialog.querySelector("[data-back]");
  var previous = dialog.querySelector("[data-go='-1']");
  var next = dialog.querySelector("[data-go='1']");
  var trail = [];
  var opener = null;

  function targetOf(link) {
    var target = document.getElementById(link.getAttribute("href").slice(1));
    return target && (target.classList.contains("detail") || target.classList.contains("lane"))
      ? target
      : null;
  }

  function render() {
    var target = trail[trail.length - 1];
    var copy = target.cloneNode(true);
    // The page keeps the elements with these identifiers.
    copy.removeAttribute("id");
    Array.prototype.forEach.call(copy.querySelectorAll("[id]"), function (element) {
      element.removeAttribute("id");
    });
    copy.removeAttribute("aria-labelledby");
    body.replaceChildren(copy);
    var heading = target.querySelector("h3");
    dialog.setAttribute("aria-label", heading ? heading.textContent : "Details");
    var siblings = stepsOf(target);
    var position = siblings.indexOf(target);
    var isStep = position >= 0;
    dialog.classList.toggle("wide", target.classList.contains("lane"));
    back.hidden = trail.length < 2;
    previous.hidden = next.hidden = !isStep;
    previous.disabled = position <= 0;
    next.disabled = position === siblings.length - 1;
    where.hidden = !isStep;
    if (isStep) {
      var stage = target.parentNode.getAttribute("data-stage");
      where.textContent = (stage ? stage + " · " : "") + "Step " + (position + 1) + " of " + siblings.length;
    }
    dialog.scrollTop = 0;
  }

  function open(target, fresh) {
    if (fresh) {
      trail = [];
    }
    trail.push(target);
    render();
    if (!dialog.open) {
      dialog.showModal();
    }
  }

  document.addEventListener("click", function (event) {
    var link = event.target.closest && event.target.closest(selector);
    if (!link || event.metaKey || event.ctrlKey || event.shiftKey) {
      return;
    }
    var target = targetOf(link);
    if (!target) {
      return;
    }
    event.preventDefault();
    if (!dialog.contains(link)) {
      opener = link;
    }
    open(target, !dialog.contains(link));
  });

  function step(offset) {
    var siblings = stepsOf(trail[trail.length - 1]);
    var position = siblings.indexOf(trail[trail.length - 1]) + offset;
    if (siblings.length && position >= 0 && position < siblings.length) {
      trail[trail.length - 1] = siblings[position];
      render();
    }
  }

  dialog.addEventListener("click", function (event) {
    var button = event.target.closest && event.target.closest("button");
    if (button && button.hasAttribute("data-go")) {
      step(Number(button.getAttribute("data-go")));
    } else if (button && button.hasAttribute("data-back")) {
      trail.pop();
      render();
    } else if (event.target === dialog || (button && button.hasAttribute("data-close"))) {
      dialog.close();
    }
  });

  dialog.addEventListener("keydown", function (event) {
    if (!stepsOf(trail[trail.length - 1]).length) {
      return;
    }
    if (event.key === "ArrowRight") {
      step(1);
    } else if (event.key === "ArrowLeft") {
      step(-1);
    }
  });

  dialog.addEventListener("close", function () {
    if (opener) {
      opener.focus();
    }
  });
})();
