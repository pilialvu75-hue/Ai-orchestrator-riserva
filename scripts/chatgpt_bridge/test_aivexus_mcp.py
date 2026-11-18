"""Offline protocol and transport regression tests for the ChatGPT MCP adapter.

These use a synthetic HTTP stub, NOT a real AIVEXUS instance.
"""
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch

import aivexus_mcp as mcp


class _SyntheticApp(BaseHTTPRequestHandler):
    calls = []

    def do_GET(self):
        self.__class__.calls.append(("GET", self.path))
        if self.headers.get("Authorization") != "Bearer " + ("x" * 40):
            self.send_response(401)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        response = {"instance_id": "synthetic-stub", "app_version": "not-real",
                    "runtime_status": "ready", "platform": "windows"}
        if self.path.startswith("/v1/tests/"):
            response = {"request_id": self.path.rsplit("/", 1)[-1],
                        "status": "completed", "elapsed_ms": 123}
        self.wfile.write(json.dumps(response).encode("utf-8"))

    def do_POST(self):
        self.__class__.calls.append(("POST", self.path))
        if self.headers.get("Authorization") != "Bearer " + ("x" * 40):
            self.send_response(401)
            self.end_headers()
            return
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = json.loads(raw)
        self.send_response(202)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"request_id": payload["request_id"],
                                     "kind": payload["kind"],
                                     "status": "queued"}).encode("utf-8"))

    def log_message(self, fmt, *args):
        pass


class ProtocolTest(unittest.TestCase):
    def test_initialize_and_tools(self):
        response = mcp._handle({"jsonrpc": "2.0", "id": 1, "method": "initialize"})
        self.assertEqual(response["result"]["serverInfo"]["name"], "aivexus-local-test-bridge")
        response = mcp._handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.assertEqual(len(response["result"]["tools"]), 6)

    def test_notifications_have_no_response(self):
        self.assertIsNone(mcp._handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))

    def test_no_command_or_arbitrary_url_tools(self):
        result = mcp._dispatch_tool("execute_shell", {"command": "whoami"})
        self.assertEqual(result, {"error": "unknown_tool"})

    def test_invalid_id_prevents_transport(self):
        with patch.object(mcp, "_call_app") as stub:
            result = mcp._dispatch_tool("test_start",
                                        {"request_id": "../secrets", "kind": "runtime"})
        self.assertIn("error", result)
        stub.assert_not_called()

    def test_other_test_kinds_rejected(self):
        with patch.object(mcp, "_call_app") as stub:
            result = mcp._dispatch_tool("test_start",
                                        {"request_id": "synthetic-123", "kind": "application"})
        self.assertEqual(result["error"], "invalid_or_unsupported_test")
        stub.assert_not_called()

    def test_comparison(self):
        with patch.object(mcp, "_call_app",
                          side_effect=[{"elapsed_ms": 200, "status": "completed"},
                                       {"elapsed_ms": 120, "status": "completed"}]):
            r = mcp._dispatch_tool("test_compare",
                                   {"first_request_id": "synthetic-a",
                                    "second_request_id": "synthetic-b"})
        self.assertEqual(r["elapsed_delta_ms"], -80)

    def test_no_token_no_connection(self):
        with patch.dict("os.environ", {"AIVEXUS_BRIDGE_TOKEN": ""}):
            self.assertEqual(mcp._call_app("GET", "/v1/instance")["error"],
                             "bridge_token_missing")


class LoopbackTest(unittest.TestCase):
    def setUp(self):
        _SyntheticApp.calls = []
        self.httpd = HTTPServer(("127.0.0.1", 0), _SyntheticApp)
        self.worker = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.worker.start()
        self.host_patch = patch.object(mcp, "HOST",
                                       "http://127.0.0.1:" + str(self.httpd.server_port))
        self.env_patch = patch.dict("os.environ", {"AIVEXUS_BRIDGE_TOKEN": "x" * 40})
        self.host_patch.start()
        self.env_patch.start()

    def tearDown(self):
        self.env_patch.stop()
        self.host_patch.stop()
        self.httpd.shutdown()
        self.httpd.server_close()
        self.worker.join(timeout=2)

    def test_mcp_to_synthetic_app_status(self):
        result = mcp._handle({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                              "params": {"name": "instance_info", "arguments": {}}})
        body = json.loads(result["result"]["content"][0]["text"])
        self.assertEqual(body["instance_id"], "synthetic-stub")
        self.assertEqual(_SyntheticApp.calls, [("GET", "/v1/instance")])

    def test_mcp_to_synthetic_app_test_start(self):
        result = mcp._handle({
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": {"name": "test_start",
                       "arguments": {"request_id": "synthetic-123", "kind": "runtime"}}})
        body = json.loads(result["result"]["content"][0]["text"])
        self.assertEqual(body["status"], "queued")
        self.assertEqual(_SyntheticApp.calls, [("POST", "/v1/tests")])

    def test_bad_token_denied_without_echo(self):
        with patch.dict("os.environ", {"AIVEXUS_BRIDGE_TOKEN": "y" * 40}):
            result = mcp._dispatch_tool("instance_info", {})
        self.assertEqual(result["http_status"], 401)
        self.assertNotIn("y" * 40, json.dumps(result))


if __name__ == "__main__":
    unittest.main()
