"""Unit tests — run inside the Docker build stage, so a broken app never ships."""

import json
import os
import socket
import tempfile
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer

import app


class ServiceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        for k in ("APP_NAME", "VERSION", "CONFIG_DIR"):
            os.environ.pop(k, None)

    def get(self, path):
        with urllib.request.urlopen(self.base + path, timeout=2) as r:
            return r.status, json.loads(r.read())

    def test_healthz(self):
        self.assertEqual(self.get("/healthz"), (200, {"status": "ok"}))

    def test_root_reads_env_per_request(self):
        os.environ.update(APP_NAME="a", VERSION="1")
        _, body = self.get("/")
        self.assertEqual(body, {"app": "a", "version": "1", "pod": socket.gethostname()})
        os.environ["APP_NAME"] = "b"  # changed at runtime -> must follow
        self.assertEqual(self.get("/")[1]["app"], "b")

    def test_config_dir_overrides_env(self):
        os.environ.update(APP_NAME="from-env", VERSION="1")
        with tempfile.TemporaryDirectory() as d:
            os.environ["CONFIG_DIR"] = d
            self.assertEqual(self.get("/")[1]["app"], "from-env")  # no file yet
            with open(os.path.join(d, "APP_NAME"), "w") as fh:
                fh.write("from-file\n")
            self.assertEqual(self.get("/")[1]["app"], "from-file")

    def test_unknown_path_404(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self.get("/nope")
        self.assertEqual(ctx.exception.code, 404)
        ctx.exception.close()


if __name__ == "__main__":
    unittest.main()
