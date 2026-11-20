"""Line clients for Pane's two bench sockets: the control channel (`bench.sock`) and the MCP connector (`mcp.sock`)."""

import json
import socket


class LineClient:
    """One JSON object per line over a Unix socket, answered in order."""

    def __init__(self, path: str):
        self.path = path
        self._socket = None
        self._buffer = b""

    def _connect(self):
        if self._socket is None:
            self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._socket.connect(self.path)
            self._buffer = b""

    def send(self, obj: dict):
        self._connect()
        self._socket.sendall(json.dumps(obj).encode() + b"\n")

    def receive(self, timeout: float = 150) -> dict:
        self._socket.settimeout(timeout)
        while b"\n" not in self._buffer:
            chunk = self._socket.recv(65536)
            if not chunk:
                self.close()
                raise ConnectionError("Pane closed the socket")
            self._buffer += chunk
        line, _, self._buffer = self._buffer.partition(b"\n")
        return json.loads(line)

    def call(self, obj: dict, timeout: float = 150) -> dict:
        try:
            self.send(obj)
            return self.receive(timeout)
        except (OSError, ValueError):
            self.close()
            raise

    def close(self):
        if self._socket is not None:
            try:
                self._socket.close()
            finally:
                self._socket = None


class MCPClient(LineClient):
    """Pane's connector, spoken as an AI app would. Every call and reply is kept in `records` for the run's evidence."""

    def __init__(self, path: str):
        super().__init__(path)
        self._next = 0
        self.records = []

    def _request(self, method: str, params: dict | None = None, timeout: float = 150) -> dict:
        self._next += 1
        message = {"jsonrpc": "2.0", "id": self._next, "method": method}
        if params is not None:
            message["params"] = params
        reply = self.call(message, timeout)
        self.records.append({"request": message, "reply": reply})
        return reply

    def initialize(self, client_name: str = "Claude"):
        reply = self._request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                             "clientInfo": {"name": client_name, "version": "1.0"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return reply

    def tools(self) -> list:
        return self._request("tools/list").get("result", {}).get("tools", [])

    def call_tool(self, name: str, args: dict) -> tuple:
        reply = self._request("tools/call", {"name": name, "arguments": args})
        if "error" in reply:
            return reply["error"].get("message", "error"), True
        result = reply.get("result", {})
        text = "\n".join(part.get("text", "") for part in result.get("content", []) if part.get("type") == "text")
        return text, bool(result.get("isError"))
