/*
 * The About card.
 *
 * The circular mark in the top left opens it. The wordmark beside the mark
 * still goes to the chart, which is what it did before.
 *
 * This loads on every page, because the bar is on every page. A control that
 * works on one tab and looks dead on the other three is the same fault the
 * power button had.
 */

const aboutPanel = document.getElementById("about-panel");
const aboutOpen = document.getElementById("about-open");
const aboutClose = document.getElementById("about-close");

const ABOUT_HIDDEN = "modal-hidden";

function showAbout() {
  aboutPanel.classList.remove(ABOUT_HIDDEN);
  document.body.dataset.aboutPanel = "open";
}

function hideAbout() {
  aboutPanel.classList.add(ABOUT_HIDDEN);
  document.body.dataset.aboutPanel = "closed";
}

if (aboutOpen && aboutPanel) {
  aboutOpen.addEventListener("click", showAbout);
  aboutClose.addEventListener("click", hideAbout);

  /* A tap on the dark surround closes it, the way a person expects. */
  aboutPanel.addEventListener("click", (event) => {
    if (event.target === aboutPanel) hideAbout();
  });

  document.body.dataset.aboutPanel = "closed";

  /*
   * about=show opens the card, the same as a press on the mark.
   *
   * A headless browser cannot tap, and a gate has to prove the mark opens
   * something. The lag slider and the power dialog carry the same kind of hook,
   * for the same reason.
   */
  if (new URLSearchParams(window.location.search).get("about") === "show") {
    showAbout();
  }
}
