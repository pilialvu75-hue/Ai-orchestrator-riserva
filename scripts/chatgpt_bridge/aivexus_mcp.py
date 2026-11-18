#!/usr/bin/env python3
"""Minimal MCP stdio adapter for the REAL running AIVEXUS Windows instance.

Python standard library only. No shells, web access, arbitrary paths, or
model inference exist inside this adapter. Stdout is exclusively MCP JSON-RPC.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

HOST = "http://127.0.0.1:47941"
PROTOCOL_VERSION = "2025-06-18"
MAX_RESPONSE_BYTES = 32768

TOOLS = [
    {
        "name": "instance_info",
        "description": "Identify the running AIVEXUS instance, app, platform, runtime and model. Does not start AIVEXUS.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "diagnostics_read",
        "description": "Read only synthetic test status and runtime health; never personal logs or chats.",
        "inputSchema": {
            "type": "object",
            "properties": {"request_id": {"type": "string", "minLength": 8, "maxLength": 64}},
            "required": ["request_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "test_start",
        "description": "Run AIVEXUS' actual local runtime self-test. Supply a unique stable ID; retries MUST reuse it. The test prompt is fixed and synthetic.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "request_id": {"type": "string", "pattern": "^[A-Za-z0-9_-]{8,64}$"},
                "kind": {"type": "string", "enum": ["runtime"]},
            },
            "required": ["request_id", "kind"],
            "additionalProperties": False,
        },
    },
    {
        "name": "test_status",
        "description": "Recover an existing test state; does not re-execute anything.",
        "inputSchema": {
            "type": "object",
            "properties": {"request_id": {"type": "string", "minLength": 8, "maxLength": 64}},
            "required": ["request_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "test_cancel",
        "description": "Request cooperative cancellation of an active synthetic runtime test.",
        "inputSchema": {
            "type": "object",
            "properties": {"request_id": {"type": "string", "minLength": 8, "maxLength": 64}},
            "required": ["request_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "test_compare",
        "description": "Compare statuses and durations of two completed synthetic AIVEXUS tests.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "first_request_id": {"type": "string", "minLength": 8, "maxLength": 64},
                "second_request_id": {"type": "string", "minLength": 8, "maxLength": 64},
            },
            "required": ["first_request_id", "second_request_id"],
            "additionalProperties": False,
        },
    },
]


def _id(value):
    return (isinstance(value, str) and 8 <= len(value) <= 64
            and all(ch.isascii() and (ch.isalnum() or ch in "_-") for ch in value))


def _call_app(method, path, body=None):
    """Only talks to fixed loopback routes. Never follows redirects."""
    secret = os.environ.get("AIVEXUS_BRIDGE_TOKEN", "")
    if len(secret) < 32:
        return {"error": "bridge_token_missing", "hint": "Configure the same local secret in both processes."}
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        HOST + path, data=data, method=method,
        headers={"Authorization": "Bearer " + secret, "Content-Type": "application/json"},
    )
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(req, timeout=8) as response:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if len(payload) > MAX_RESPONSE_BYTES:
                return {"error": "bridge_response_too_large"}
            return json.loads(payload)
    except urllib.error.HTTPError as exc:
        return {"error": "bridge_http_error", "http_status": exc.code}
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
        return {"error": "aivexus_not_reachable", "hint": "Start the opted-in AIVEXUS build on this ASUS."}
    except (ValueError, UnicodeDecodeError):
        return {"error": "invalid_bridge_response"}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _dispatch_tool(name, arguments):
    if not isinstance(arguments, dict):
        return {"error": "invalid_arguments"}
    if name == "instance_info" and not arguments:
        return _call_app("GET", "/v1/instance")
    if name in ("diagnostics_read", "test_status", "test_cancel"):
        ident = arguments.get("request_id")
        if set(arguments) != {"request_id"} or not _id(ident):
            return {"error": "invalid_request_id"}
        if name == "diagnostics_read":
            return _call_app("GET", "/v1/diagnostics?request_id=" + ident)
        if name == "test_status":
            return _call_app("GET", "/v1/tests/" + ident)
        return _call_app("POST", "/v1/tests/" + ident + "/cancel", {})
    if name == "test_start":
        ident = arguments.get("request_id")
        if set(arguments) != {"request_id", "kind"} or not _id(ident) or arguments.get("kind") != "runtime":
            return {"error": "invalid_or_unsupported_test"}
        return _call_app("POST", "/v1/tests", {"request_id": ident, "kind": "runtime"})
    if name == "test_compare":
        one, two = arguments.get("first_request_id"), arguments.get("second_request_id")
        if set(arguments) != {"first_request_id", "second_request_id"} or not _id(one) or not _id(two):
            return {"error": "invalid_request_id"}
        a = _call_app("GET", "/v1/tests/" + one)
        b = _call_app("GET", "/v1/tests/" + two)
        if "error" in a or "error" in b:
            return {"error": "comparison_unavailable", "first": a, "second": b}
        ta, tb = a.get("elapsed_ms"), b.get("elapsed_ms")
        delta = tb - ta if isinstance(ta, int) and isinstance(tb, int) else None
        return {"first": a, "second": b, "elapsed_delta_ms": delta}
    return {"error": "unknown_tool"}


def _handle(message):
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        return None
    request_id = message.get("id")
    method = message.get("method", "")
    if request_id is None:  # MCP notifications have no response.
        return None
    params = message.get("params") or {}
    if method == "initialize":
        result = {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "aivexus-local-test-bridge", "version": "0.1.0"},
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        if not isinstance(params, dict):
            result = {"content": [{"type": "text", "text": '{"error":"invalid_params"}'}], "isError": True}
        else:
            output = _dispatch_tool(params.get("name"), params.get("arguments", {}))
            result = {
                "content": [{"type": "text", "text": json.dumps(output, ensure_ascii=False)}],
                "isError": "error" in output,
            }
    else:
        return {"jsonrpc": "2.0", "id": request_id,
                "error": {"code": -32601, "message": "Method not found"}}
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def main():
    for line in sys.stdin:
        try:
            message = json.loads(line)
            reply = _handle(message)
            if reply is not None:
                sys.stdout.write(json.dumps(reply, separators=(",", ":"), ensure_ascii=False) + "\n")
                sys.stdout.flush()
        except (ValueError, TypeError, KeyError):
            # Never print a traceback or secrets into the MCP stdout channel.
            sys.stdout.write('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}\n')
            sys.stdout.flush()


if __name__ == "__main__":
    main()
