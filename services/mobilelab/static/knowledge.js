/*
 * The knowledge page.
 *
 * The article text comes from the markdown file on disk, rendered by the API on
 * every request. This page holds NO copy of the text. The example content in
 * knowledge.html is a shell, and this file overwrites it before a person can
 * read it.
 *
 * Edit docs/kb/*.md, reload, and the change appears. That is gate 2.
 */

const el = (id) => document.getElementById(id);

const state = { articles: [], current: null };

function wantedSlug() {
  return new URLSearchParams(window.location.search).get("a");
}

function renderList() {
  const list = el("article-list");
  list.innerHTML = "";

  state.articles.forEach((article) => {
    const item = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.dataset.slug = article.slug;
    button.setAttribute("aria-current", String(article.slug === state.current));
    button.innerHTML =
      `${article.title}<span class="list-summary">${article.subtitle}${article.reading_minutes ? ` &middot; ${article.reading_minutes} min read` : ""}</span>`;
    button.addEventListener("click", () => show(article.slug, true));
    item.appendChild(button);
    list.appendChild(item);
  });

  el("list-note").textContent =
    `${state.articles.length} articles. Each one takes a few minutes to read.`;
  document.body.dataset.articleCount = String(state.articles.length);
}

async function show(slug, push) {
  const response = await fetch(`/api/kb/${encodeURIComponent(slug)}`);
  if (!response.ok) {
    el("article-body").innerHTML = "<h1>That article is missing.</h1>";
    document.body.dataset.status = "error";
    return;
  }
  const article = await response.json();

  /*
   * Replace the shell. The example markup carries the shell-example class, so
   * removing it here also proves the shell did not survive.
   */
  const body = el("article-body");
  body.classList.remove("shell-example");
  body.innerHTML = article.html;

  el("source-note").textContent =
    `This page is rendered from ${article.source_file}. That file is the source of truth. ` +
    `Edit it and reload to change this page.`;

  state.current = slug;
  document.title = `${article.title} - Mobile Lab Station`;
  document.body.dataset.status = "ready";
  document.body.dataset.kbSlug = slug;
  document.body.dataset.kbTitle = article.title;
  document.body.dataset.kbSourceFile = article.source_file;
  document.body.dataset.kbHeading =
    (body.querySelector("h1") || {}).textContent || "";
  document.body.dataset.kbShellVisible = String(
    body.classList.contains("shell-example")
  );

  renderList();

  if (push) {
    const url = new URL(window.location.href);
    url.searchParams.set("a", slug);
    window.history.replaceState({}, "", url);
  }
}

async function start() {
  const response = await fetch("/api/kb");
  state.articles = await response.json();

  if (!state.articles.length) {
    el("article-body").innerHTML = "<h1>There are no articles yet.</h1>";
    document.body.dataset.status = "empty";
    return;
  }

  const slug = wantedSlug() || state.articles[0].slug;
  await show(slug, false);
}

start();
