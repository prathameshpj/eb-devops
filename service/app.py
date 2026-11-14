"""Tiny HTTP service for the take-home.

GET /         -> {"app": APP_NAME, "version": VERSION, "pod": hostname}
GET /healthz  -> 200 {"status": "ok"}

Configuration is resolved on *every request*, not cached at start-up:

  1. If CONFIG_DIR is set and contains a file named APP_NAME / VERSION, that
     file's content wins. In Kubernetes the chart mounts the ConfigMap there,
     and the kubelet refreshes mounted ConfigMaps in place (~1 min), so a
     patched ConfigMap is picked up without a pod restart.
  2. Otherwise the environment variable of the same name is used (this is what
     `docker run -e APP_NAME=...` and the chart's envFrom provide).

Only the Python standard library is used: nothing to pin, nothing to scan.
"""

import json
import logging
import os
import signal
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULTS = {"APP_NAME": "unknown", "VERSION": "unknown"}

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("service")


def get_setting(key: str) -> str:
    """Return a setting: mounted ConfigMap file first, then env, then default."""
    config_dir = os.environ.get("CONFIG_DIR")
    if config_dir:
        try:
            with open(os.path.join(config_dir, key), encoding="utf-8") as fh:
                return fh.read().strip()
        except OSError:
            pass  # file not present -> fall back to the environment
    return os.environ.get(key, DEFAULTS.get(key, ""))


class Handler(BaseHTTPRequestHandler):
    server_version = "demo-service"
    sys_version = ""

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
        path = self.path.split("?", 1)[0]
        if path == "/":
            self._send_json(200, {
                "app": get_setting("APP_NAME"),
                "version": get_setting("VERSION"),
                "pod": socket.gethostname(),
            })
        elif path == "/healthz":
            self._send_json(200, {"status": "ok"})
        else:
            self._send_json(404, {"error": "not found"})

    def log_message(self, fmt: str, *args) -> None:
        # Keep probe noise out of the logs; log everything else.
        if not self.path.startswith("/healthz"):
            log.info("%s %s", self.address_string(), fmt % args)


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.daemon_threads = True

    def shutdown(signum, _frame):
        log.info("received signal %s, shutting down", signum)
        # shutdown() blocks until serve_forever() returns, so call it off-thread.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    log.info("listening on :%d", port)
    server.serve_forever()
    server.server_close()
    log.info("stopped")


if __name__ == "__main__":
    main()
