// The played run on the workflow page: one feature from idea to merge.
//
// The page holds the finished drawing, which shows the complete workflow.
// This script plays the walkthrough when the reader asks for it, and can
// pause, resume, and return to the complete drawing. It also switches between
// running a feature step by step and unattended, which differ in who decides
// about review findings. Every element it
// changes carries data-k; the drawing exists twice (across and down), and
// both are played together.

(function () {
  "use strict";

  var root = document.querySelector("[data-run]");
  if (!root) {
    return;
  }

  function all(key) {
    return Array.prototype.slice.call(root.querySelectorAll('[data-k="' + key + '"]'));
  }

  var lengths = new Map();
  function length(path) {
    if (!lengths.has(path)) {
      lengths.set(path, path.getTotalLength() || 1);
    }
    return lengths.get(path);
  }

  var lines = Array.prototype.slice.call(root.querySelectorAll("[data-log]"));
  var finals = {};
  root.querySelectorAll('[data-k^="stat:"]').forEach(function (element) {
    finals[element.getAttribute("data-k")] = [element.textContent, element.getAttribute("class")];
  });

  // --- What a moment of the run can change ----------------------------------

  function draw(key, progress) {
    all("ink:" + key).forEach(function (path, index) {
      var total = length(path);
      path.style.strokeDasharray = total + " " + total;
      path.style.strokeDashoffset = String(total * (1 - progress));
      path.style.opacity = progress > 0 ? "1" : "0";
      var head = all("head")[index];
      if (head && progress > 0 && progress < 1) {
        var point = path.getPointAtLength(total * progress);
        head.setAttribute("cx", point.x);
        head.setAttribute("cy", point.y);
      } else if (head && progress >= 1) {
        head.setAttribute("cx", -20);
        head.setAttribute("cy", -20);
      }
    });
    all("label:" + key).forEach(function (label) {
      label.classList.toggle("on", progress > 0.4);
    });
  }

  function bar(progress, text, tone) {
    all("bar").forEach(function (path) {
      var total = length(path);
      path.style.strokeDasharray = total + " " + total;
      path.style.strokeDashoffset = String(total * (1 - progress));
      path.style.opacity = progress > 0 ? "1" : "0";
    });
    stat("impl", text === undefined ? (progress <= 0 ? "waiting" : Math.round(progress * 100) + "%") : text, tone);
  }

  function state(id, value, mark) {
    all("node:" + id).forEach(function (node) {
      node.setAttribute("data-state", value);
    });
    all("mark:" + id).forEach(function (element) {
      element.textContent = mark || "";
    });
  }

  function stat(id, text, tone) {
    all("stat:" + id).forEach(function (element) {
      element.textContent = text;
      element.setAttribute("class", "run-stat" + (tone ? " " + tone : ""));
    });
  }

  function gate(id, on) {
    all("gate:" + id).forEach(function (element) {
      element.classList.toggle("on", on);
    });
  }

  function log(index, current) {
    lines.forEach(function (line, position) {
      line.classList.toggle("pending", position > index);
      line.classList.toggle("now", current !== false && position === index);
    });
  }

  var nodes = ["req", "plan", "prev", "approve", "issue", "checks", "review", "triage", "commit", "pr", "ci", "merge"];
  var inks = [
    "req-plan", "plan-prev", "prev-approve", "approve-issue", "to-impl", "from-impl", "checks-review",
    "review-triage", "triage-commit", "commit-pr", "pr-ci", "ci-merge", "loop-plan", "loop-fix",
  ];

  function reset() {
    inks.forEach(function (key) {
      draw(key, 0);
    });
    bar(0);
    nodes.forEach(function (id) {
      state(id, "idle");
      stat(id, "waiting");
      gate(id, false);
    });
    log(-1);
  }

  // --- The run, in seconds ---------------------------------------------------

  var steps = [];
  function at(time, action) {
    steps.push({ start: time, action: action, order: steps.length });
  }
  function during(start, end, action) {
    steps.push({ start: start, end: end, action: action, order: steps.length });
  }
  function active(time, id, text) {
    at(time, function () {
      state(id, "active");
      stat(id, text);
    });
  }
  function done(time, id, text) {
    at(time, function () {
      state(id, "done");
      stat(id, text, "ok");
    });
  }
  function line(start, end, key) {
    during(start, end, function (progress) {
      draw(key, progress);
    });
  }

  // Stage 1: plan the project.
  active(0.3, "req", "questions");
  at(0.5, function () { log(0); });
  at(1.4, function () { gate("req", true); log(1); });
  done(1.7, "req", "approved");
  line(1.7, 2.2, "req-plan");
  active(2.2, "plan", "writing");
  at(2.4, function () { log(2); });
  done(3.2, "plan", "roadmap ready");
  line(3.2, 3.7, "plan-prev");
  active(3.7, "prev", "reviewing");
  at(4.5, function () { stat("prev", "2 findings", "warn"); log(3); });
  line(4.6, 5.3, "loop-plan");
  active(5.3, "plan", "revising");
  done(6.0, "plan", "revised");
  active(6.0, "prev", "reviewing");
  done(6.7, "prev", "0 findings");
  line(6.7, 7.2, "prev-approve");
  active(7.2, "approve", "your decision");
  at(7.8, function () { gate("approve", true); log(4); });
  done(8.0, "approve", "recorded");

  // Stage 2: build the feature.
  line(8.0, 8.7, "approve-issue");
  active(8.7, "issue", "creating");
  at(8.9, function () { log(5); });
  done(9.3, "issue", "created");
  line(9.3, 9.6, "to-impl");
  at(9.6, function () { log(6); });
  during(9.6, 11.6, function (progress) { bar(progress); });
  line(11.6, 11.9, "from-impl");
  active(11.9, "checks", "running");
  at(12.6, function () { state("checks", "fail", "✗"); stat("checks", "1 check fails", "warn"); log(7); });
  during(12.9, 13.4, function (progress) { bar(1 - 0.3 * progress, "repairing", "warn"); });
  during(13.4, 14.4, function (progress) { bar(0.7 + 0.3 * progress, progress < 1 ? "repairing" : "done", progress < 1 ? "warn" : "ok"); });
  active(14.4, "checks", "running again");
  done(15.0, "checks", "passed");
  line(15.0, 15.4, "checks-review");
  active(15.4, "review", "reviewing");
  at(16.2, function () { stat("review", "1 finding", "warn"); log(8); });
  line(16.3, 16.7, "review-triage");
  at(16.7, function () {
    state("triage", "active");
    stat("triage", unattended() ? "agent decides" : "your decision");
  });
  at(17.3, function () { gate("triage", true); stat("triage", "fix now", "warn"); log(9); });
  line(17.4, 18.4, "loop-fix");
  during(18.4, 19.3, function (progress) { bar(0.75 + 0.25 * progress, progress < 1 ? "fixing" : "done", progress < 1 ? "warn" : "ok"); });
  active(19.3, "checks", "running again");
  done(19.8, "checks", "passed");
  active(19.8, "review", "reviewing");
  at(20.5, function () { log(10); });
  done(20.5, "review", "0 findings");
  done(20.6, "triage", "resolved");
  line(20.6, 21.0, "triage-commit");
  active(21.0, "commit", "checking");
  at(21.3, function () { log(11); });
  done(21.5, "commit", "recorded");
  line(21.5, 21.9, "commit-pr");
  active(21.9, "pr", "opening");
  at(22.1, function () { log(12); });
  done(22.4, "pr", "open");
  line(22.4, 22.8, "pr-ci");
  active(22.8, "ci", "running");
  done(23.6, "ci", "green");
  line(23.6, 24.0, "ci-merge");
  active(24.0, "merge", "your decision");
  at(24.6, function () { gate("merge", true); log(13); });
  done(24.9, "merge", "merged");

  steps.sort(function (a, b) {
    return a.start - b.start || a.order - b.order;
  });

  function ease(progress) {
    return progress < 0.5 ? 2 * progress * progress : 1 - Math.pow(-2 * progress + 2, 2) / 2;
  }

  function unattended() {
    return root.getAttribute("data-mode") === "unattended";
  }

  var frame = 0;
  var playButton = root.querySelector(".run-play");
  var finishButton = root.querySelector(".run-finish");
  var status = "complete"; // complete, playing, or paused
  var elapsed = 0;
  var finished = new Set();

  function label() {
    root.classList.toggle("playing", status !== "complete");
    if (playButton) {
      playButton.textContent = status === "playing" ? "Pause" : status === "paused" ? "Resume" : "Play walkthrough";
    }
    if (finishButton) {
      finishButton.hidden = status === "complete";
    }
  }

  function finish() {
    cancelAnimationFrame(frame);
    reset();
    steps.forEach(function (step) {
      step.action(1);
    });
    Object.keys(finals).forEach(function (key) {
      all(key).forEach(function (element) {
        element.textContent = finals[key][0];
        element.setAttribute("class", finals[key][1]);
      });
    });
    log(lines.length - 1, false);
    status = "complete";
    label();
  }

  function run() {
    var began = performance.now() - elapsed * 1000;
    function tick(now) {
      elapsed = (now - began) / 1000;
      steps.forEach(function (step) {
        if (finished.has(step) || elapsed < step.start) {
          return;
        }
        if (step.end === undefined) {
          step.action(1);
          finished.add(step);
        } else {
          var progress = Math.min(1, (elapsed - step.start) / (step.end - step.start));
          step.action(ease(progress));
          if (progress >= 1) {
            finished.add(step);
          }
        }
      });
      if (finished.size < steps.length) {
        frame = requestAnimationFrame(tick);
      } else {
        finish();
      }
    }
    status = "playing";
    label();
    frame = requestAnimationFrame(tick);
  }

  function play() {
    cancelAnimationFrame(frame);
    reset();
    elapsed = 0;
    finished = new Set();
    run();
  }

  function pause() {
    cancelAnimationFrame(frame);
    status = "paused";
    label();
  }

  finish();
  var controls = root.querySelector(".run-controls");
  if (controls && playButton && finishButton) {
    controls.hidden = false;
    playButton.addEventListener("click", function () {
      if (status === "playing") {
        pause();
      } else if (status === "paused") {
        run();
      } else {
        play();
      }
    });
    finishButton.addEventListener("click", finish);
  }

  // The two ways to run a feature.
  var modes = root.querySelector(".run-modes");
  if (modes) {
    modes.hidden = false;
    modes.addEventListener("click", function (event) {
      var button = event.target.closest && event.target.closest("[data-set-mode]");
      if (!button) {
        return;
      }
      root.setAttribute("data-mode", button.getAttribute("data-set-mode"));
      modes.querySelectorAll("[data-set-mode]").forEach(function (other) {
        other.setAttribute("aria-pressed", other === button ? "true" : "false");
      });
    });
  }
})();
