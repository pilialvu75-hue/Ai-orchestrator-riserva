#!/usr/bin/env python3
"""Opt-in real-model Cantiere capability probe. Never generates or applies code.

Requires server-side zero-monetary-cost authorization and Cloudflare Access
service credentials. No default provider, no paid fallback, no source upload.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CAPABILITIES = ("orchestration", "architecture_reasoning", "coding", "review")
MARKER = "AIVEXUS_CAPABILITY_OK"


def config_from_env(env):
    if env.get("CANTIERE_ZERO_COST_ROUTES_VERIFIED") != "YES":
        raise ValueError("ZERO_COST_ROUTE_AUTHORIZATION_REQUIRED")
    endpoint = env.get("CANTIERE_BROKER_URL", "").strip()
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/"):
        raise ValueError("HTTPS_BROKER_ORIGIN_REQUIRED")
    client_id = env.get("CANTIERE_CF_ACCESS_CLIENT_ID", "").strip()
    client_secret = env.get("CANTIERE_CF_ACCESS_CLIENT_SECRET", "").strip()
    if not client_id or not client_secret:
        raise ValueError("CLOUDFLARE_ACCESS_SERVICE_CREDENTIALS_REQUIRED")
    return endpoint.rstrip("/"), {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-Requested-With": "XMLHttpRequest",
        "CF-Access-Client-Id": client_id,
        "CF-Access-Client-Secret": client_secret,
    }


def send_json(origin, headers, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    method = "GET" if payload is None else "POST"
    request = urllib.request.Request(origin + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=95) as response:
            raw = response.read(32769)
            if len(raw) > 32768:
                raise ValueError("RESPONSE_TOO_LARGE")
            if "json" not in response.headers.get("Content-Type", "").lower():
                raise ValueError("NON_JSON_BROKER_RESPONSE")
            return json.loads(raw)
    except urllib.error.HTTPError as error:
        # Do not log response bodies, headers or Access credentials.
        raise RuntimeError("BROKER_HTTP_" + str(error.code)) from None


def main(env=None, transport=send_json):
    env = os.environ if env is None else env
    origin, headers = config_from_env(env)
    health = transport(origin, headers, "/api/cantiere/capabilities")
    if not isinstance(health, dict) or not isinstance(health.get("capabilities"), list):
        raise ValueError("INVALID_BROKER_CAPABILITIES")
    if not set(CAPABILITIES).issubset(set(health["capabilities"])):
        raise ValueError("FOUR_ROLE_CAPABILITIES_MISSING")
    outcomes = []
    for capability in CAPABILITIES:
        started = time.monotonic()
        payload = {
            "version": 1,
            "capability": capability,
            "messages": [{"role": "user", "content": (
                "Synthetic diagnostic. Reply exactly " + MARKER +
                ". Do not generate software or include any personal information."
            )}],
            "maxTokens": 64,
            "temperature": 0.0,
            "topP": 1.0,
        }
        result = transport(origin, headers, "/api/cantiere/inference", payload)
        if not isinstance(result, dict) or not isinstance(result.get("text"), str):
            raise ValueError("INVALID_INFERENCE_RESPONSE_" + capability)
        if result["text"].strip() != MARKER:
            raise ValueError("REAL_MODEL_MARKER_MISMATCH_" + capability)
        model = result.get("model")
        if not isinstance(model, str) or not model.strip():
            raise ValueError("MODEL_PROVENANCE_MISSING_" + capability)
        outcomes.append({
            "capability": capability,
            "responded": True,
            "model": model,
            "elapsed_ms": round((time.monotonic() - started) * 1000),
        })
    # Keep receipts synthetic: no prompts, responses, auth material or remote endpoints.
    print(json.dumps({
        "gate": "REAL_MODEL_FOUR_ROLE_PREFLIGHT",
        "status": "PASS",
        "autonomous_star_generation_verified": False,
        "android_local_verified": False,
        "windows_local_verified": False,
        "roles": outcomes,
    }, sort_keys=True))
    return outcomes


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("CANTIERE_REAL_MODEL_PREFLIGHT_FAIL: " + str(exc), file=sys.stderr)
        sys.exit(1)
