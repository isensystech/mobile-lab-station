"""The knowledge base, and the sensor suite.

THE MARKDOWN IS THE SOURCE OF TRUTH.

Architecture section 8 locks it: the articles are static markdown, in-repo,
versioned and reviewable. This module reads those files from disk and renders
them on every request. Nothing keeps a second copy of the text.

`knowledge.html` is a shell. It carries the layout and an example of the
intended rendering. The example never reaches the screen, because the page
replaces it with the rendered file. Edit the markdown, reload, and the change
appears. That is gate 2.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

import markdown

REPO_ROOT = Path(__file__).resolve().parents[2]
KB_DIR = REPO_ROOT / "docs" / "kb"

FRONT_MATTER = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)

MARKDOWN_EXTENSIONS = ["extra", "sane_lists", "toc"]


@dataclass
class Article:
    slug: str
    title: str
    subtitle: str
    order: int
    reading_minutes: int
    metrics: list[str]
    path: Path

    def as_dict(self) -> dict:
        return {
            "slug": self.slug,
            "title": self.title,
            "subtitle": self.subtitle,
            "order": self.order,
            "reading_minutes": self.reading_minutes,
            "metrics": self.metrics,
            "source_file": str(self.path.relative_to(REPO_ROOT)),
        }


def _int_or(value: str | None, fallback: int) -> int:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return fallback


def _string_list(value: str | None) -> list[str]:
    """Read `metrics: [sal_PSU, EC_mScm]` from the front matter."""
    if not value:
        return []
    text = value.strip().strip("[]")
    return [part.strip().strip("'\"") for part in text.split(",") if part.strip()]


def _split_front_matter(text: str) -> tuple[dict[str, str], str]:
    match = FRONT_MATTER.match(text)
    if not match:
        return {}, text
    fields: dict[str, str] = {}
    for line in match.group(1).splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip()
    return fields, text[match.end() :]


def _read(path: Path) -> tuple[dict[str, str], str]:
    return _split_front_matter(path.read_text(encoding="utf-8"))


def list_articles() -> list[Article]:
    """Every article on disk, in reading order."""
    articles: list[Article] = []
    if not KB_DIR.is_dir():
        return articles

    for path in sorted(KB_DIR.glob("*.md")):
        fields, _ = _read(path)
        articles.append(
            Article(
                slug=fields.get("slug") or path.stem,
                title=fields.get("title") or path.stem,
                # The articles in this repository use `subtitle`. `summary` is
                # accepted too, so an older file keeps working.
                subtitle=fields.get("subtitle") or fields.get("summary") or "",
                # No `order` means "sort by filename". That is enough while the
                # knowledge base is two articles long.
                order=_int_or(fields.get("order"), 50),
                reading_minutes=_int_or(
                    fields.get("reading_time_min") or fields.get("reading_minutes"), 0
                ),
                metrics=_string_list(fields.get("metrics")),
                path=path,
            )
        )
    articles.sort(key=lambda a: (a.order, a.path.name))
    return articles


def find_article(slug: str) -> Article | None:
    for article in list_articles():
        if article.slug == slug:
            return article
    return None


def render_article(article: Article) -> dict:
    """Read the file NOW and render it. Never cache, never copy.

    A cache would make the page and the file drift apart, and a person editing
    the markdown would not see the change. Two articles are small enough that
    reading from disk on each request costs nothing.
    """
    _, body = _read(article.path)
    html = markdown.markdown(body, extensions=MARKDOWN_EXTENSIONS, output_format="html5")
    return {**article.as_dict(), "html": html, "markdown": body}
