"""Read single members of a remote ZIP (an IPSW or OTA) with HTTP range requests.

Only the central directory and the requested member are fetched. A server that ignores Range (a
200 reply) or answers with the wrong Content-Range is refused, so a multi-gigabyte image is never
downloaded by accident. ZIP64 is handled by `zipfile`.
"""
from __future__ import annotations

import io
import re
import struct
import zipfile
import zlib

from .http import Client, FetchError

_CONTENT_RANGE = re.compile(r"^bytes (\d+)-(\d+)/(\d+|\*)$")
_LOCAL_HEADER = struct.Struct("<IHHHHHIIIHH")   # 30 bytes, signature 0x04034b50


class Unsupported(Exception):
    """The archive can be reached but not read this way (encrypted, odd compression, over a cap)."""


def _ranged(client: Client, url: str, start: int, end: int, stream: bool = False):
    resp = client.open(url, headers={"Range": f"bytes={start}-{end}"})
    status = getattr(resp, "status", None) or resp.getcode()
    if status != 206:
        resp.close()
        raise FetchError(f"{url}: range request answered with HTTP {status}, not 206",
                         retryable=status in (200, 429, 500, 502, 503, 504), status=status)
    m = _CONTENT_RANGE.match(resp.headers.get("Content-Range", ""))
    if not m or int(m.group(1)) != start or int(m.group(2)) != end:
        resp.close()
        raise FetchError(f"{url}: Content-Range {resp.headers.get('Content-Range')!r} does not match {start}-{end}",
                         retryable=True)
    total = None if m.group(3) == "*" else int(m.group(3))
    if stream:
        return resp, total
    try:
        body = resp.read(end - start + 2)
    finally:
        resp.close()
    if len(body) != end - start + 1:
        raise FetchError(f"{url}: got {len(body)} bytes for range {start}-{end}", retryable=True)
    return body, total


class RangeFile(io.RawIOBase):
    """A read-only, seekable view of a remote file, one range request per read."""

    def __init__(self, client: Client, url: str):
        self.client, self.url, self.pos = client, url, 0
        _, total = _ranged(client, url, 0, 0)
        if total is None:
            raise FetchError(f"{url}: server did not report the file size", retryable=False)
        self.size = total

    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos

    def seek(self, offset, whence=io.SEEK_SET):
        self.pos = {io.SEEK_SET: offset, io.SEEK_CUR: self.pos + offset, io.SEEK_END: self.size + offset}[whence]
        return self.pos

    def readinto(self, buf):
        if not len(buf) or self.pos >= self.size:
            return 0
        end = min(self.pos + len(buf), self.size) - 1
        data, _ = _ranged(self.client, self.url, self.pos, end)
        buf[:len(data)] = data
        self.pos += len(data)
        return len(data)


class RemoteZip:
    def __init__(self, client: Client, url: str):
        if url.lower().endswith(".aea"):
            raise Unsupported("aea-encrypted")
        self.client, self.url = client, url
        try:
            self.zip = zipfile.ZipFile(io.BufferedReader(RangeFile(client, url), buffer_size=1 << 16))
        except zipfile.BadZipFile as e:
            raise Unsupported(f"not a readable zip: {e}") from None

    def names(self) -> list[str]:
        return self.zip.namelist()

    def info(self, name: str) -> zipfile.ZipInfo | None:
        try:
            return self.zip.getinfo(name)
        except KeyError:
            return None

    def read(self, name: str, max_size: int) -> bytes:
        info = self.info(name)
        if info is None:
            raise KeyError(name)
        buf = io.BytesIO()
        self.fetch_member(name, buf, max_compressed=max_size, max_size=max_size)   # one ranged GET
        return buf.getvalue()

    def fetch_member(self, name: str, dest, *, max_compressed: int, max_size: int) -> int:
        """Stream one member into the binary file `dest` with a single ranged GET; returns its size."""
        info = self.info(name)
        if info is None:
            raise KeyError(name)
        if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise Unsupported(f"{name}: compression method {info.compress_type}")
        if info.compress_size > max_compressed or info.file_size > max_size:
            raise Unsupported(f"{name}: {info.compress_size}/{info.file_size} bytes, over the cap")
        header, _ = _ranged(self.client, self.url, info.header_offset, info.header_offset + _LOCAL_HEADER.size - 1)
        fields = _LOCAL_HEADER.unpack(header)
        if fields[0] != 0x04034B50:
            raise Unsupported(f"{name}: bad local header")
        start = info.header_offset + _LOCAL_HEADER.size + fields[9] + fields[10]
        written, crc = 0, 0
        inflate = zlib.decompressobj(-15) if info.compress_type == zipfile.ZIP_DEFLATED else None
        if info.compress_size == 0:
            return 0
        resp, _ = _ranged(self.client, self.url, start, start + info.compress_size - 1, stream=True)
        try:
            remaining = info.compress_size
            while remaining:
                chunk = resp.read(min(1 << 20, remaining))
                if not chunk:
                    raise FetchError(f"{self.url}: member body ended early", retryable=True)
                remaining -= len(chunk)
                out = inflate.decompress(chunk, max_size - written + 1) if inflate else chunk
                if inflate and inflate.unconsumed_tail:
                    raise Unsupported(f"{name}: inflates past the {max_size}-byte cap")
                written += len(out)
                if written > max_size:
                    raise Unsupported(f"{name}: inflates past the {max_size}-byte cap")
                crc = zlib.crc32(out, crc)
                dest.write(out)
            if inflate:
                tail = inflate.flush()
                written += len(tail)
                crc = zlib.crc32(tail, crc)
                dest.write(tail)
        finally:
            resp.close()
        if written != info.file_size or crc != info.CRC:
            raise FetchError(f"{name}: size or CRC mismatch after download", retryable=True)
        return written
