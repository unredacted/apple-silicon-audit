"""HTTP for the watcher: standard library only, HTTPS only, bounded, and careful with the token.

Every hop of a redirect is checked against the host allowlist, and the GitHub token is attached
only to requests for api.github.com, so a redirect can never carry it elsewhere.
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = "silicon-audit-watch/1 (+https://github.com/unredacted/apple-silicon-audit)"
TOKEN_HOSTS = {"api.github.com"}
FIRMWARE_HOSTS = {"updates.cdn-apple.com", "secure-appldnld.apple.com", "appldnld.apple.com"}
ALLOWED_HOSTS = FIRMWARE_HOSTS | TOKEN_HOSTS | {
    "api.appledb.dev", "api.ipsw.me", "raw.githubusercontent.com", "github.com",
    "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    "support.apple.com", "help.apple.com", "security.apple.com",
}
MAX_REDIRECTS = 5
RETRY_STATUS = {429, 500, 502, 503, 504}
DEFAULT_MAX_BYTES = 16 << 20


class FetchError(Exception):
    """A request that did not produce a usable response. `retryable` separates outages from refusals."""

    def __init__(self, message: str, *, retryable: bool, status: int | None = None):
        super().__init__(message)
        self.retryable = retryable
        self.status = status


class Response:
    def __init__(self, status: int, headers: dict, body: bytes, url: str):
        self.status = status
        self.headers = {k.lower(): v for k, v in headers.items()}
        self.body = body
        self.url = url

    def json(self):
        return json.loads(self.body)

    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Redirects are followed by hand so every hop is checked."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def check_url(url: str, allowed: set[str] = ALLOWED_HOSTS) -> str:
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https":
        raise FetchError(f"refusing non-HTTPS URL: {url}", retryable=False)
    if parts.hostname not in allowed:
        raise FetchError(f"refusing host not on the allowlist: {parts.hostname}", retryable=False)
    return parts.hostname


class Client:
    """`opener(request, timeout)` returns an object with `.status`, `.headers`, `.read(n)` and
    `.close()`; tests pass a fake. HTTP errors come back as responses, not exceptions."""

    def __init__(self, token: str | None = None, opener=None, sleep=time.sleep,
                 allowed: set[str] = ALLOWED_HOSTS, timeout: float = 30, attempts: int = 3):
        self.token = token
        self.allowed = allowed
        self.timeout = timeout
        self.attempts = attempts
        self.sleep = sleep
        self._opener = opener or self._default_opener()

    @staticmethod
    def _default_opener():
        built = urllib.request.build_opener(_NoRedirect)

        def open_(request, timeout):
            try:
                return built.open(request, timeout=timeout)
            except urllib.error.HTTPError as e:   # 3xx (unfollowed), 4xx, 5xx all arrive here
                return e
        return open_

    def _headers(self, url: str, extra: dict | None) -> dict:
        headers = {"User-Agent": USER_AGENT}
        if self.token and urllib.parse.urlsplit(url).hostname in TOKEN_HOSTS:
            headers["Authorization"] = f"Bearer {self.token}"
        headers.update(extra or {})
        return headers

    def open(self, url: str, *, method: str = "GET", headers: dict | None = None):
        """The final response object after redirects and retries, unread. Callers close it."""
        for attempt in range(self.attempts):
            current = url
            try:
                for _ in range(MAX_REDIRECTS + 1):
                    check_url(current, self.allowed)
                    req = urllib.request.Request(current, method=method, headers=self._headers(current, headers))
                    resp = self._opener(req, self.timeout)
                    status = getattr(resp, "status", None) or resp.getcode()
                    if status in (301, 302, 303, 307, 308):
                        location = resp.headers.get("Location")
                        resp.close()
                        if not location:
                            raise FetchError(f"redirect without Location from {current}", retryable=False)
                        current = urllib.parse.urljoin(current, location)
                        continue
                    break
                else:
                    raise FetchError(f"too many redirects from {url}", retryable=False)
            except OSError as e:   # URLError, timeouts, resets; FetchError is not an OSError
                if attempt + 1 < self.attempts:
                    self.sleep(2 ** (attempt + 1))
                    continue
                raise FetchError(f"{url}: {e}", retryable=True) from None
            if status in RETRY_STATUS and attempt + 1 < self.attempts:
                resp.close()
                self.sleep(2 ** (attempt + 1))
                continue
            resp.final_url = current
            return resp
        raise FetchError(f"{url}: retries exhausted", retryable=True)

    def request(self, url: str, *, method: str = "GET", headers: dict | None = None,
                max_bytes: int = DEFAULT_MAX_BYTES, ok=(200,)) -> Response:
        resp = self.open(url, method=method, headers=headers)
        try:
            status = getattr(resp, "status", None) or resp.getcode()
            if status not in ok:
                raise FetchError(f"{url}: HTTP {status}", retryable=status in RETRY_STATUS, status=status)
            body = b"" if method == "HEAD" else resp.read(max_bytes + 1)
            if len(body) > max_bytes:
                raise FetchError(f"{url}: response larger than {max_bytes} bytes", retryable=False)
            return Response(status, dict(resp.headers.items()), body, getattr(resp, "final_url", url))
        finally:
            resp.close()

    def get_json(self, url: str, **kw):
        try:
            return self.request(url, **kw).json()
        except ValueError as e:
            raise FetchError(f"{url}: not JSON ({e})", retryable=False) from None
