/*
 * The on-screen power control. Architecture section 9.
 *
 * Students will unplug the station. A clean shutdown button gives them a better
 * option, and the Pi's own button does the same thing in hardware.
 *
 * TWO STEPS ON PURPOSE. This page runs fullscreen on a touchscreen all day. One
 * tap must never stop the station in the middle of a demo, so the first tap
 * only asks the question.
 *
 * The API refuses this from anywhere but the station itself, so a laptop on the
 * same network cannot switch the station off.
 */

const panel = document.getElementById("power-panel");
const openButton = document.getElementById("power-open");
const confirmButton = document.getElementById("power-confirm");
const restartButton = document.getElementById("power-restart");
const cancelButton = document.getElementById("power-cancel");
const result = document.getElementById("power-result");

let closeTimer = null;

/*
 * The dialog uses the shared modal classes, the same as every other popup on
 * this screen.
 *
 * It used to add and remove a class called power-hidden. That class does not
 * exist in the stylesheet. The refactor to 1024 by 600 moved this dialog onto
 * the shared .modal pattern and this file was not moved with it, so the button
 * ran, removed a class that was never there, and the dialog stayed hidden
 * behind .modal-hidden. The button appeared dead.
 */
const HIDDEN = "modal-hidden";

function show() {
  panel.classList.remove(HIDDEN);
  result.textContent = "";
  document.body.dataset.powerPanel = "open";
  /* If nobody answers, close it again. An open dialog on a demo screen is a bug. */
  clearTimeout(closeTimer);
  closeTimer = setTimeout(hide, 20000);
}

function hide() {
  panel.classList.add(HIDDEN);
  document.body.dataset.powerPanel = "closed";
  clearTimeout(closeTimer);
}

async function send(action, button) {
  clearTimeout(closeTimer);
  confirmButton.disabled = true;
  restartButton.disabled = true;
  result.textContent = "Working...";

  try {
    const response = await fetch(`/api/power/${action}`, { method: "POST" });
    const body = await response.json();
    if (!response.ok) {
      result.textContent = body.detail || "The station refused that.";
      confirmButton.disabled = false;
      restartButton.disabled = false;
      document.body.dataset.powerResult = "refused";
      return;
    }
    result.textContent = body.message;
    document.body.dataset.powerResult = action;
    button.textContent = "Done";
  } catch (error) {
    result.textContent = String(error.message || error);
    confirmButton.disabled = false;
    restartButton.disabled = false;
    document.body.dataset.powerResult = "error";
  }
}

if (openButton) {
  openButton.addEventListener("click", show);
  cancelButton.addEventListener("click", hide);
  confirmButton.addEventListener("click", () => send("shutdown", confirmButton));
  restartButton.addEventListener("click", () => send("restart", restartButton));
  document.body.dataset.powerPanel = "closed";

  /*
   * power=ask opens the dialog, the same as a tap on the button.
   *
   * A headless browser cannot tap, and a gate has to prove this button opens
   * something. It stops exactly where a person stops: at the question. It never
   * shuts anything down, because that still needs the second press.
   *
   * The lag slider carries the same kind of hook, for the same reason.
   */
  if (new URLSearchParams(window.location.search).get("power") === "ask") {
    show();
  }
}
