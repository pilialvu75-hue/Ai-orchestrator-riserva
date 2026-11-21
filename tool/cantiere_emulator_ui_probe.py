#!/usr/bin/env python3
"""Black-box acceptance of the exact generated release APK on an Android emulator.

The Cantiere role replies upstream are deterministic CI fixtures, not real
LLM inference. This probe only certifies live Android UI behavior.
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

BOUNDS = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")


def adb(*args, timeout=30, binary=False):
    p = subprocess.run(["adb", *args], capture_output=True,
                       timeout=timeout, check=False)
    if p.returncode:
        raise RuntimeError(f"adb {args!r} failed ({p.returncode}): "
                           + p.stderr.decode("utf-8", "replace")[-1200:])
    return p.stdout if binary else p.stdout.decode("utf-8", "replace")


def nodes_from_xml(xml_text):
    root = ET.fromstring(xml_text)
    return [
        {
            "labels": tuple(
                value.strip() for key in ("text", "content-desc")
                if (value := node.attrib.get(key, "")).strip()
            ),
            "bounds": node.attrib.get("bounds", ""),
        }
        for node in root.iter("node")
    ]


def get_ui():
    # UIAutomator interrogates the installed app's accessibility hierarchy.
    adb("shell", "uiautomator", "dump", "/sdcard/cantiere-window.xml",
        timeout=35)
    xml = adb("exec-out", "cat", "/sdcard/cantiere-window.xml")
    return xml, nodes_from_xml(xml)


def find_label(nodes, expected):
    matches = [n for n in nodes if expected in n["labels"]]
    if len(matches) != 1:
        raise AssertionError(
            f"Expected one visible node labelled {expected!r}, "
            f"observed {len(matches)}"
        )
    return matches[0]


def tap_label(nodes, label):
    bounds = BOUNDS.fullmatch(find_label(nodes, label)["bounds"])
    if bounds is None:
        raise AssertionError(f"Button {label!r} has no valid bounds")
    x1, y1, x2, y2 = map(int, bounds.groups())
    if x2 <= x1 or y2 <= y1:
        raise AssertionError(f"Button {label!r} has zero-size bounds")
    adb("shell", "input", "tap", str((x1+x2)//2), str((y1+y2)//2))


def await_counter(value, timeout=25):
    end = time.monotonic() + timeout
    last_xml, last_nodes = "", []
    while time.monotonic() < end:
        try:
            last_xml, last_nodes = get_ui()
            if any(str(value) in n["labels"] for n in last_nodes):
                return last_xml, last_nodes
        except (RuntimeError, ET.ParseError):
            pass
        time.sleep(1)
    raise AssertionError(
        f"Counter {value} not visible; last labels="
        f"{[n['labels'] for n in last_nodes]!r}"
    )


def screenshot(path):
    path.write_bytes(adb("exec-out", "screencap", "-p", binary=True))
    if path.stat().st_size < 1024:
        raise AssertionError("Empty Android screenshot")


def run(apk, package, out):
    out.mkdir(parents=True, exist_ok=True)
    if not apk.is_file() or not apk.stat().st_size:
        raise AssertionError("Generated release APK missing")
    receipt = {
        "apk_sha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
        "scenario": "counter", "target": "Android API 35 emulator",
        "inference": "deterministic scripted roles",
        "real_model_generation_verified": False,
        "physical_s24_verified": False,
        "ui_behavior_verified": False,
        "steps": [],
    }
    try:
        adb("install", "-r", str(apk), timeout=120)
        if "package:" not in adb("shell", "pm", "path", package):
            raise AssertionError("Installed package not found")
        adb("shell", "am", "force-stop", package)
        adb("shell", "monkey", "-p", package, "-c",
            "android.intent.category.LAUNCHER", "1")
        _, nodes = await_counter(0)
        find_label(nodes, "Contatore")
        screenshot(out / "initial.png")
        receipt["steps"].append("launch:0")

        for button, expected in (("+", 1), ("+", 2), ("-", 1), ("Reset", 0)):
            _, nodes = get_ui()
            tap_label(nodes, button)
            xml, _ = await_counter(expected)
            (out / f"after-{len(receipt['steps'])}.xml").write_text(
                xml, encoding="utf-8"
            )
            receipt["steps"].append(f"tap:{button}:value:{expected}")

        screenshot(out / "final.png")
        if not adb("shell", "pidof", package).strip():
            raise AssertionError("App process stopped before final verification")
        receipt["ui_behavior_verified"] = True
    except Exception as exc:
        receipt["failure"] = f"{type(exc).__name__}: {exc}"
        try:
            screenshot(out / "failure.png")
            (out / "failure-ui.xml").write_text(get_ui()[0], encoding="utf-8")
        except Exception:
            pass
        raise
    finally:
        (out / "result.json").write_text(
            json.dumps(receipt, indent=2), encoding="utf-8"
        )
    print("CANTIERE_EMULATOR_COUNTER_UI_PASS: actual taps and values verified")
    print("Does NOT certify real-model star generation or S24 LOCAL build")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--apk", required=True, type=Path)
    p.add_argument("--package", required=True)
    p.add_argument("--out", required=True, type=Path)
    a = p.parse_args()
    run(a.apk.resolve(), a.package, a.out.resolve())


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"CANTIERE_EMULATOR_COUNTER_UI_FAIL: {e}", file=sys.stderr)
        sys.exit(1)
