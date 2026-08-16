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

function show() {
  panel.classList.remove("power-hidden");
  result.textContent = "";
  document.body.dataset.powerPanel = "open";
  /* If nobody answers, close it again. An open dialog on a demo screen is a bug. */
  clearTimeout(closeTimer);
  closeTimer = setTimeout(hide, 20000);
}

function hide() {
  panel.classList.add("power-hidden");
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
}
