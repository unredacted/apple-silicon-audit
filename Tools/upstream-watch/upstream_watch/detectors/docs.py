"""Apple's Platform Security guide and Security Research blog.

The guide's runtime-protection table marks support with images, so cells are read from each image's
`originalImageName` (IL_green_checkmark / IL_red_x), never from text. Anything else in a cell is a
parse failure: a layout change should open a health issue, not read as "not supported".
"""
from __future__ import annotations

import datetime
import hashlib
import html
import re
import xml.etree.ElementTree as ET
from html.parser import HTMLParser

from ..http import Client, FetchError

GUIDE_URL = "https://support.apple.com/guide/security/operating-system-integrity-sec8b776536b/web"
PDF_URL = "https://help.apple.com/pdf/security/en_US/apple-platform-security-guide.pdf"
REVISIONS_URL = "https://support.apple.com/guide/security/document-revision-history-secb82d6b274/web"
BLOG_URL = "https://security.apple.com/blog/feed.rss"
TABLE_LABEL = "System security features for Apple silicon devices"
_YES, _NO = "IL_green_checkmark", "IL_red_x"


class ParseError(Exception):
    pass


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(text).replace("–", "-").replace("‑", "-")).strip()


class _TableParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tables = []          # [{"label", "rows": [[cell]]}]
        self._depth = 0
        self._cell = None

    def handle_starttag(self, tag, attrs):
        a = {k: (v or "") for k, v in attrs if k}
        if tag == "table":
            self._depth += 1
            if self._depth == 1:
                self.tables.append({"label": a.get("aria-label", ""), "rows": []})
        elif self._depth != 1:
            return
        elif tag == "tr":
            self.tables[-1]["rows"].append([])
        elif tag in ("td", "th"):
            self._cell = {"text": [], "strong": [], "images": [], "small": [], "_in": None}
        elif self._cell is not None and tag in ("strong", "small"):
            self._cell["_in"] = tag
            self._cell[tag].append("")
        elif self._cell is not None and tag == "img":
            self._cell["images"].append(a.get("originalimagename", a.get("originalImageName", "")))

    def handle_endtag(self, tag):
        if tag == "table":
            self._depth -= 1
        elif self._depth == 1 and tag in ("td", "th") and self._cell is not None:
            self._cell.pop("_in")
            self.tables[-1]["rows"][-1].append(self._cell)
            self._cell = None
        elif self._cell is not None and tag in ("strong", "small"):
            self._cell["_in"] = None

    def handle_data(self, data):
        if self._cell is not None:
            self._cell["text"].append(data)
            if self._cell["_in"]:
                self._cell[self._cell["_in"]][-1] += data


def parse_guide(page: str) -> dict:
    """{"published", "columns", "rows": {label: ["Y", "N^1", ...]}, "footnotes": {n: {"sha", "excerpt"}}}."""
    p = _TableParser()
    p.feed(page)
    tables = [t for t in p.tables if t["label"] == TABLE_LABEL] or \
             [t for t in p.tables if t["rows"] and t["rows"][0] and _norm("".join(t["rows"][0][0]["text"])) == "Feature"
              and any(_YES in img for r in t["rows"] for c in r for img in c["images"])]
    if not tables:
        raise ParseError("runtime-protection table not found")
    header, *body = tables[0]["rows"]
    columns = [" | ".join(_norm(s) for s in c["strong"] if _norm(s)) or _norm("".join(c["text"])) for c in header[1:]]
    rows = {}
    for r in body:
        label = _norm("".join(r[0]["text"]))
        cells = []
        for c in r[1:]:
            marks = [img for img in c["images"] if _YES in img or _NO in img]
            if len(marks) != 1:
                raise ParseError(f"cell in row {label!r} has {len(marks)} support marks: {c['images']}")
            notes = "".join(f"^{_norm(s)}" for s in c["small"] if _norm(s))
            cells.append(("Y" if _YES in marks[0] else "N") + notes)
        if len(cells) != len(columns):
            raise ParseError(f"row {label!r} has {len(cells)} cells for {len(columns)} columns")
        rows[label] = cells
    if not rows:
        raise ParseError("table has no rows")
    after = page[page.find("</table>", page.find(TABLE_LABEL)):]
    after = after[:after.find("<div")] if "<div" in after else after[:5000]
    footnotes = {}
    for n, text in re.findall(r"<p><em>(\d+):\s*</em>(.*?)</p>", after, re.S):
        clean = _norm(re.sub(r"<[^>]+>", "", text))
        footnotes[n] = {"sha": hashlib.sha256(clean.encode()).hexdigest()[:16], "excerpt": clean[:100]}
    m = re.search(r"Published Date:\s*([A-Z][a-z]+ \d{1,2}, \d{4})", page)
    if not m:
        raise ParseError("Published Date not found")
    published = datetime.datetime.strptime(m.group(1), "%B %d, %Y").date().isoformat()
    return {"published": published, "columns": columns, "rows": rows, "footnotes": footnotes}


def parse_revisions(page: str) -> dict:
    sections = []
    for sid, title, body in re.findall(
            r'<div id="(sec[0-9a-f]+)" class="Subhead"><h2 class="Name">(.*?)</h2>(.*?)</div>', page, re.S):
        text = _norm(re.sub(r"<[^>]+>", " ", body))
        sections.append({"id": sid, "title": _norm(title)[:60], "sha": hashlib.sha256(text.encode()).hexdigest()[:16]})
    if not sections:
        raise ParseError("no revision sections found")
    return {"sections": sections}


def parse_blog(feed: bytes) -> dict:
    try:
        root = ET.fromstring(feed)
    except ET.ParseError as e:
        raise ParseError(f"feed is not XML: {e}") from None
    items = []
    for item in root.iter("item"):
        link = (item.findtext("link") or "").strip()
        if re.match(r"^https://security\.apple\.com/blog/[A-Za-z0-9._/-]+$", link):
            items.append({"link": link, "title": _norm(item.findtext("title") or "")[:120]})
    if not items:
        raise ParseError("feed has no blog items")
    return {"items": sorted(items, key=lambda i: i["link"])}


def observe(client: Client, b) -> None:
    def run(key, fn):
        try:
            b.snapshot(key, fn())
        except FetchError as e:
            b.failed(key, e, "network" if e.retryable else "parse")
        except (ParseError, ValueError) as e:
            b.failed(key, e, "parse")

    run("docs:guide", lambda: parse_guide(client.request(GUIDE_URL, max_bytes=8 << 20).text()))

    def pdf():
        r = client.request(PDF_URL, method="HEAD")
        return {"etag": r.headers.get("etag", ""), "last_modified": r.headers.get("last-modified", ""),
                "length": r.headers.get("content-length", "")}
    run("docs:pdf", pdf)
    run("docs:revisions", lambda: parse_revisions(client.request(REVISIONS_URL, max_bytes=8 << 20).text()))
    run("docs:blog", lambda: parse_blog(client.request(BLOG_URL, max_bytes=2 << 20).body))
