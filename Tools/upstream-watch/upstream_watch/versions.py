"""Version and build-number comparisons."""
from __future__ import annotations

import datetime
import re

_BUILD = re.compile(r"^(\d+)([A-Z])(\d+)([a-z]?)$")


def components(version: str | None) -> list[int] | None:
    if not version:
        return None
    parts = version.split(".")
    if not all(p.isdigit() for p in parts):
        return None
    return [int(p) for p in parts]


def at_least(version: str | None, minimum: str) -> bool:
    """Mirrors `DocumentedMatrix.Exception.applies`: "27" is "27.0", and an unreadable version cannot
    rule an exception out, so it counts as reached."""
    os, low = components(version), components(minimum)
    if os is None or low is None:
        return True
    width = max(len(os), len(low))
    os += [0] * (width - len(os))
    low += [0] * (width - len(low))
    return os >= low


def build_key(build: str):
    """Sort key for Apple build numbers: 24A446 < 24A5279h < 24B100. Unparseable builds sort first."""
    m = _BUILD.match(build)
    if not m:
        return (-1, "", -1, build)
    return (int(m.group(1)), m.group(2), int(m.group(3)), m.group(4))


def train(build: str) -> int | None:
    """The leading number of a build (24 in 24A446), which advances once per major release."""
    m = _BUILD.match(build)
    return int(m.group(1)) if m else None


def is_beta_build(build: str) -> bool:
    m = _BUILD.match(build)
    return bool(m and m.group(4))


def split_index_key(key: str) -> tuple[str, str, str]:
    """"watchOS;24R365-S11" → ("watchOS", "24R365", "S11")."""
    os, _, rest = key.partition(";")
    build, _, suffix = rest.partition("-")
    return os, build, suffix


def add_days(date: str, days: int) -> str:
    return (datetime.date.fromisoformat(date) + datetime.timedelta(days=days)).isoformat()


def ordinal(date: str) -> int:
    return datetime.date.fromisoformat(date).toordinal()


def major(version: str | None) -> int | None:
    c = components(version)
    return c[0] if c else None
