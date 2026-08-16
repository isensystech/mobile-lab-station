/*
 * Does this page fit the screen?
 *
 * The station screen is 1024 by 600 and a person uses it with a finger.
 * Scrolling the page to reach a control is a defect, so every page reports
 * whether it overflows. ops/verify-chart.sh reads this.
 */
function reportFit() {
  const doc = document.documentElement;
  const overflowY = doc.scrollHeight - window.innerHeight;
  const overflowX = doc.scrollWidth - window.innerWidth;
  document.body.dataset.viewport = `${window.innerWidth}x${window.innerHeight}`;
  document.body.dataset.contentHeight = String(doc.scrollHeight);
  document.body.dataset.overflowY = String(Math.max(0, overflowY));
  document.body.dataset.overflowX = String(Math.max(0, overflowX));
  document.body.dataset.fits = String(overflowY <= 1 && overflowX <= 1);
}

window.addEventListener("load", () => setTimeout(reportFit, 900));
window.addEventListener("resize", reportFit);
setTimeout(reportFit, 2500);
