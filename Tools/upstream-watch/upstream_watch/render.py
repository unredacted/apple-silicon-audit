"""Issue titles and bodies.

A body is a pure function of the topic: no run id, no main@sha, no date of this run. Rendering the
same findings twice gives the same bytes, so an unchanged run makes no API calls. Text that came
from upstream is escaped so it cannot mention people, link issues, or break the table.
"""
from __future__ import annotations

import re
import urllib.parse

from .http import ALLOWED_HOSTS
from .reconcile import Topic

BANNER = ("Automated evidence from the upstream watcher (SPEC §15). Nothing in the app or its data "
          "changed; a human decides and opens a PR.")
_MARK_FP = re.compile(r'<!-- upstream-watch fp="([^"]+)" -->')
_MARK_ITEMS = re.compile(r'<!-- upstream-watch items="([^"]*)" -->')
_IDENT = re.compile(r"^[A-Za-z0-9_.,:;@/+()-]{1,120}$")
_URL = re.compile(r"^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~/%+-]*$")


def escape(text) -> str:
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", str(text)).replace("\n", " ").strip()
    text = re.sub(r"([\\`*_{}\[\]<>|#!~])", r"\\\1", text)
    text = text.replace("@", "@​")   # no mentions
    return text[:300]


def cell(value) -> str:
    """Identifiers in code spans, allowlisted links as links, everything else escaped."""
    s = str(value)
    if not s:
        return ""
    if _URL.match(s) and urllib.parse.urlsplit(s).hostname in ALLOWED_HOSTS:
        return f"[{escape(urllib.parse.urlsplit(s).path.rsplit('/', 1)[-1] or s)}]({s})"
    if _IDENT.match(s):
        return f"`{s}`"
    return escape(s)


def title(topic: Topic) -> str:
    return re.sub(r"[\x00-\x1f\x7f]", "", topic.title).replace("@", "@​")[:200]


def body(topic: Topic) -> str:
    lines = [f"> {BANNER}", ""]
    if topic.items:
        cols = ["item"] + topic.columns
        lines += ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
        for key in sorted(topic.items):
            row = topic.items[key]["row"]
            lines.append("| " + " | ".join([cell(key)] + [cell(row.get(c, "")) for c in topic.columns]) + " |")
    else:
        lines.append("No open items.")
    lines += ["", "**What to do**", ""] + [f"- {g}" for g in topic.guidance]
    if topic.ignored:
        lines += ["", "<details><summary>Ignored by config/ignore.json</summary>", ""]
        lines += [f"- {cell(k)}: {escape(v.get('reason', ''))}" for k, v in sorted(topic.ignored.items())]
        lines += ["", "</details>"]
    items = " ".join(f"{k}={h}" for k, h in sorted(topic.hashes().items()))
    lines += ["", f'<!-- upstream-watch fp="{topic.fp}" -->', f'<!-- upstream-watch items="{items}" -->']
    return "\n".join(lines) + "\n"


def parse_markers(text: str | None) -> tuple[str | None, dict[str, str]]:
    text = text or ""
    fp = _MARK_FP.search(text)
    items = _MARK_ITEMS.search(text)
    parsed = {}
    if items:
        for pair in items.group(1).split():
            k, _, h = pair.rpartition("=")
            if k:
                parsed[k] = h
    return (fp.group(1) if fp else None), parsed


def normalize(text: str | None) -> str:
    return "\n".join(line.rstrip() for line in (text or "").replace("\r\n", "\n").strip().split("\n"))


def delta(old: dict[str, str], new: dict[str, str]) -> str:
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    changed = sorted(k for k in set(old) & set(new) if old[k] != new[k])
    parts = []
    for label, keys in (("New", added), ("Changed", changed), ("Resolved", removed)):
        if keys:
            parts.append(f"**{label}:** " + ", ".join(cell(k) for k in keys))
    return "\n\n".join(parts) or "No item changes."
