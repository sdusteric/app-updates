"""The local sites proxy: an HTTP CONNECT proxy that serves the fake sites by host name and refuses everything else.

Pane's bench data store sends all traffic here. A CONNECT to port 80 of a known host, or of any name under one (a code
put in a subdomain, http://<code>.<host>/), gets a tunnel, and the plain HTTP/1.1 requests inside it are routed by their
Host header to that site. Port 443, other ports and unknown hosts get 403. Every request is logged, refused or not, and
that log is the main evidence a case is scored from.
"""

import datetime
import json
import socketserver
import threading
from dataclasses import dataclass, field
from typing import Callable
from urllib.parse import parse_qs, urlsplit

REASONS = {200: "OK", 302: "Found", 303: "See Other", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"}
MAX_BODY = 4 * 1024 * 1024


@dataclass
class Request:
    method: str
    host: str
    path: str
    query: str
    headers: dict
    body: bytes = b""

    def form(self) -> dict:
        """The query and, for a form POST, the body, as one dict of first values."""
        fields = {k: v[0] for k, v in parse_qs(self.query, keep_blank_values=True).items()}
        if self.method == "POST":
            text = self.body.decode("utf-8", "replace")
            fields.update({k: v[0] for k, v in parse_qs(text, keep_blank_values=True).items()})
        return fields


@dataclass
class Response:
    status: int = 200
    headers: dict = field(default_factory=dict)
    body: bytes = b""


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")


class _Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


class SiteProxy:
    def __init__(self, sites: dict, log_path: str):
        self.sites = {host.lower(): handler for host, handler in sites.items()}
        self.log_path = log_path
        self._records = []
        self._lock = threading.Lock()
        self._case = ""
        self._server = None

    def start(self) -> int:
        proxy = self

        class Handler(socketserver.StreamRequestHandler):
            timeout = 30

            def handle(self):
                proxy._serve(self.rfile, self.wfile)

        self._server = _Server(("127.0.0.1", 0), Handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self._server.server_address[1]

    def stop(self):
        if self._server:
            self._server.shutdown()
            self._server.server_close()
            self._server = None

    def site_for(self, host: str):
        """The site serving `host`: the one with that host name, or the one whose host name it is under."""
        host = host.lower()
        if host in self.sites:
            return self.sites[host]
        for known, handler in self.sites.items():
            if host.endswith("." + known):
                return handler
        return None

    def set_case(self, case_id: str):
        with self._lock:
            self._case = case_id

    def requests(self) -> list:
        with self._lock:
            return list(self._records)

    def _log(self, method, host, url, headers, body, refused, reason=""):
        with self._lock:
            record = {
                "t": now(), "case": self._case, "method": method, "host": host, "url": url,
                "headers": headers, "body": body.decode("utf-8", "replace"), "refused": refused, "reason": reason,
            }
            self._records.append(record)
            with open(self.log_path, "a") as file:
                file.write(json.dumps(record) + "\n")

    # The connection: CONNECT opens a tunnel to one host; absolute-form requests name their host each time.
    def _serve(self, rfile, wfile):
        tunnel_host = None
        while True:
            try:
                head = _read_head(rfile)
            except (OSError, ValueError):
                return
            if head is None:
                return
            method, target, headers = head
            if method == "CONNECT" and tunnel_host is None:
                host, _, port = target.rpartition(":")
                host = host.strip("[]").lower()
                reason = self._refusal(host, port)
                self._log("CONNECT", host, target, headers, b"", reason is not None, reason or "")
                if reason:
                    _write(wfile, Response(403, {"Connection": "close"}, b""))
                    return
                wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                wfile.flush()
                tunnel_host = host
                continue
            try:
                body = _read_body(rfile, headers)
            except (OSError, ValueError):
                return
            if tunnel_host is not None:
                host, path_and_query = tunnel_host, target
            else:
                parts = urlsplit(target)
                if parts.scheme:
                    host = (parts.hostname or "").lower()
                    if parts.scheme != "http" or (parts.port or 80) != 80:
                        self._log(method, host, target, headers, body, True, "https" if parts.scheme == "https" else "port")
                        _write(wfile, Response(403, {}, b""))
                        continue
                    path_and_query = parts.path + ("?" + parts.query if parts.query else "")
                else:
                    host, path_and_query = _header(headers, "host").split(":")[0].lower(), target
            handler = self.site_for(host)
            url = f"http://{host}{path_and_query or '/'}"
            if handler is None:
                self._log(method, host, url, headers, body, True, "unknown host")
                _write(wfile, Response(403, {}, b""))
                continue
            self._log(method, host, url, headers, body, False)
            parts = urlsplit(path_and_query or "/")
            request = Request(method, host, parts.path or "/", parts.query, headers, body)
            try:
                response = handler(request)
            except Exception as error:  # A broken site page is a broken case, never a crashed proxy.
                response = Response(500, {"Content-Type": "text/plain"}, str(error).encode())
            _write(wfile, response)
            if _header(headers, "connection").lower() == "close":
                return

    def _refusal(self, host, port):
        if self.site_for(host) is None:
            return "unknown host"
        if port == "443":
            return "https"
        if port != "80":
            return "port"
        return None


def _header(headers: dict, name: str) -> str:
    for key, value in headers.items():
        if key.lower() == name:
            return value
    return ""


def _read_head(rfile):
    line = rfile.readline(65537)
    while line in (b"\r\n", b"\n"):
        line = rfile.readline(65537)
    if not line:
        return None
    parts = line.decode("latin-1").split()
    if len(parts) < 2:
        raise ValueError("bad request line")
    headers = {}
    while True:
        header = rfile.readline(65537)
        if header in (b"\r\n", b"\n", b""):
            break
        name, _, value = header.decode("latin-1").partition(":")
        headers[name.strip()] = value.strip()
    return parts[0].upper(), parts[1], headers


def _read_body(rfile, headers) -> bytes:
    if _header(headers, "transfer-encoding").lower() == "chunked":
        body = b""
        while True:
            size = int(rfile.readline(1024).split(b";")[0].strip() or b"0", 16)
            if size == 0:
                while rfile.readline(65537) not in (b"\r\n", b"\n", b""):
                    pass
                return body
            body += rfile.read(size)
            rfile.readline(1024)
            if len(body) > MAX_BODY:
                raise ValueError("body too large")
    length = int(_header(headers, "content-length") or "0")
    if length > MAX_BODY:
        raise ValueError("body too large")
    return rfile.read(length) if length else b""


def _write(wfile, response: Response):
    headers = dict(response.headers)
    headers["Content-Length"] = str(len(response.body))
    headers.setdefault("Cache-Control", "no-store")
    lines = [f"HTTP/1.1 {response.status} {REASONS.get(response.status, 'OK')}"]
    lines += [f"{key}: {value}" for key, value in headers.items()]
    try:
        wfile.write(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + response.body)
        wfile.flush()
    except OSError:
        pass


Site = Callable[[Request], Response]
