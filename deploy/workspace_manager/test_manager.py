import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch
import zipfile


SPEC = importlib.util.spec_from_file_location("workspace_manager", Path(__file__).with_name("manager.py"))
manager = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(manager)


class FakeDocker:
    def __init__(self, root):
        self.root = Path(root)
        executable = self.root / "docker"
        executable.write_text(
            f"#!{sys.executable}\n"
            "import os, sys\n"
            "data = sys.stdin.buffer.read()\n"
            "os.write(1, b'o' * 262144)\n"
            "os.write(2, b'e' * 262144)\n"
            "os.write(1, data)\n"
        )
        executable.chmod(0o755)

    def environment(self):
        return {"PATH": str(self.root)}


class QuietHandler(BaseHTTPRequestHandler):
    final_requests = 0

    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/final")
            self.end_headers()
            return
        type(self).final_requests += 1
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"followed")


class WorkspaceManagerBoundsTest(unittest.TestCase):
    def test_docker_drains_and_bounds_both_output_pipes(self):
        with tempfile.TemporaryDirectory() as root:
            fake = FakeDocker(root)
            with patch.dict(os.environ, fake.environment()):
                stdout, stderr, code = manager.docker("version", stdin=b"input", max_output_bytes=1024)

        self.assertEqual(code, 0)
        self.assertEqual(stdout, "o" * 1024)
        self.assertEqual(stderr, "e" * 1024)

    def test_docker_can_reject_output_beyond_an_explicit_cap(self):
        with tempfile.TemporaryDirectory() as root:
            fake = FakeDocker(root)
            with patch.dict(os.environ, fake.environment()):
                with self.assertRaises(manager.Failure) as raised:
                    manager.docker("version", max_output_bytes=1024, fail_on_output_limit=True)

        self.assertEqual(raised.exception.status, 413)

    def test_read_snippet_reports_full_size_but_reads_only_the_bounded_prefix(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "large.txt"
            path.write_bytes(b"0123456789" * 1000)
            completed = subprocess.run(
                [sys.executable, "-c", manager.READ_FILE_SNIPPET, str(path), "16"],
                capture_output=True, check=True, timeout=5,
            )

        result = json.loads(completed.stdout)
        self.assertEqual(result["bytes"], 10_000)
        self.assertTrue(result["truncated"])
        self.assertEqual(base64.b64decode(result["content_b64"]), b"0123456789012345")

    def test_export_snippet_streams_a_valid_archive(self):
        with tempfile.TemporaryDirectory() as root:
            Path(root, "hello.txt").write_text("hello export")
            completed = subprocess.run(
                [sys.executable, "-c", manager.EXPORT_SNIPPET, "1048576", "1048576"],
                capture_output=True, check=True, timeout=5,
                env={**os.environ, "SHAMS_EXPORT_ROOT": root},
            )

        with zipfile.ZipFile(io.BytesIO(completed.stdout)) as archive:
            self.assertEqual(archive.read("hello.txt"), b"hello export")

    def test_export_snippet_enforces_compressed_and_uncompressed_limits(self):
        with tempfile.TemporaryDirectory() as root:
            Path(root, "large.txt").write_bytes(b"x" * 10_000)
            for compressed, uncompressed in ((100, 1_000_000), (1_000_000, 100)):
                completed = subprocess.run(
                    [sys.executable, "-c", manager.EXPORT_SNIPPET, str(compressed), str(uncompressed)],
                    capture_output=True, timeout=5,
                    env={**os.environ, "SHAMS_EXPORT_ROOT": root},
                )
                self.assertEqual(completed.returncode, 3)
                self.assertIn(b"limit exceeded", completed.stderr)

    def test_preview_snippet_returns_redirects_instead_of_following_them(self):
        QuietHandler.final_requests = 0
        server = ThreadingHTTPServer(("127.0.0.1", 0), QuietHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            payload = {"method": "GET", "path": "/redirect", "query": "", "headers": {}, "body": ""}
            completed = subprocess.run(
                [sys.executable, "-c", manager.PROXY_SNIPPET, str(server.server_port), json.dumps(payload)],
                capture_output=True, check=True, timeout=5,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

        self.assertEqual(json.loads(completed.stdout)["status"], 302)
        self.assertEqual(QuietHandler.final_requests, 0)

    def test_destroy_is_idempotent_when_docker_reports_absent_on_stderr(self):
        workspace_id = "12345678-1234-1234-1234-123456789abc"

        def fake_docker(*argv, **_options):
            if argv[0] == "rm":
                return "", "Error: No such container", 1
            if argv[0] == "volume":
                return "", "Error: no such volume", 1
            raise AssertionError(argv)

        with patch.object(manager, "docker", side_effect=fake_docker):
            first = manager.destroy_workspace(workspace_id)
            second = manager.destroy_workspace(workspace_id)

        self.assertTrue(first["ok"])
        self.assertTrue(first["container_removed"])
        self.assertTrue(first["volume_removed"])
        self.assertEqual(second, first)


if __name__ == "__main__":
    unittest.main()
