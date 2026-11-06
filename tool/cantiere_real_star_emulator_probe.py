#!/usr/bin/env python3
"""Black-box screenshot gate for real-model-generated star APK.

Measures a dark initial background and actual center-area color change after
a tap. Does not claim geometric star recognition, LOCAL autonomy, or user QA.
Uses only Python standard library. No source instrumentation or synthetic APK.
"""
import argparse
import hashlib
import json
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path


def png_pixels(raw):
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("PNG_SIGNATURE")
    pos, pixels, width, height, color_type = 8, bytearray(), 0, 0, None
    packed = bytearray()
    while pos < len(raw):
        length = struct.unpack_from(">I", raw, pos)[0]
        kind = raw[pos + 4:pos + 8]
        data = raw[pos + 8:pos + 8 + length]
        if len(data) != length:
            raise ValueError("PNG_TRUNCATED")
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, color_type, comp, filt, interlace = struct.unpack(">IIBBBBB", data)
            if depth != 8 or color_type not in (2, 6) or interlace != 0:
                raise ValueError("UNSUPPORTED_PNG_FORMAT")
        elif kind == b"IDAT":
            packed.extend(data)
        elif kind == b"IEND":
            break
    channels = 4 if color_type == 6 else 3
    if not 0 < width <= 4096 or not 0 < height <= 4096:
        raise ValueError("PNG_DIMENSIONS")
    unpacked = zlib.decompress(packed)
    stride = width * channels
    if len(unpacked) != height * (stride + 1):
        raise ValueError("PNG_DATA_SIZE")
    previous = bytearray(stride)
    offset = 0
    for _ in range(height):
        filt = unpacked[offset]
        offset += 1
        row = bytearray(unpacked[offset:offset + stride])
        offset += stride
        for i in range(stride):
            a = row[i - channels] if i >= channels else 0
            b = previous[i]
            c = previous[i - channels] if i >= channels else 0
            if filt == 1:
                row[i] = (row[i] + a) & 255
            elif filt == 2:
                row[i] = (row[i] + b) & 255
            elif filt == 3:
                row[i] = (row[i] + ((a + b) // 2)) & 255
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
            elif filt != 0:
                raise ValueError("UNSUPPORTED_PNG_FILTER")
        pixels.extend(row)
        previous = row
    return width, height, channels, pixels


def pixel_at(image, x, y):
    width, _height, channels, pixels = image
    i = (y * width + x) * channels
    return tuple(pixels[i:i + 3])


def compare_images(before, after):
    a = png_pixels(before)
    b = png_pixels(after)
    if a[:3] != b[:3]:
        raise AssertionError("SCREENSHOT_DIMENSIONS_CHANGED")
    width, height = a[:2]
    # Test the app canvas below status bar and above bottom system navigation.
    # Geometry is measured, never injected or inferred from generated source.
    left, right = width // 6, width * 5 // 6
    top, bottom = height // 4, height * 3 // 4
    samples, changed, dark = 0, 0, 0
    for y in range(top, bottom, max(1, height // 120)):
        for x in range(left, right, max(1, width // 120)):
            old, new = pixel_at(a, x, y), pixel_at(b, x, y)
            samples += 1
            if max(old) <= 42:
                dark += 1
            if sum(abs(old[i] - new[i]) for i in range(3)) >= 75:
                changed += 1
    dark_ratio, change_ratio = dark / samples, changed / samples
    if dark_ratio < 0.55:
        raise AssertionError(f"INITIAL_BACKGROUND_NOT_DARK ratio={dark_ratio:.3f}")
    if not 0.006 <= change_ratio <= 0.55:
        raise AssertionError(f"STAR_TAP_COLOR_CHANGE_NOT_OBSERVED ratio={change_ratio:.3f}")
    return {"dark_ratio": round(dark_ratio, 4), "changed_ratio": round(change_ratio, 4),
            "sample_count": samples, "changed_samples": changed}


def adb(*args, binary=False):
    result = subprocess.run(["adb", *args], capture_output=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError("ADB_COMMAND_FAILED")
    return result.stdout if binary else result.stdout.decode("utf-8", "replace")


def run(apk, package, out):
    out.mkdir(parents=True, exist_ok=True)
    if not apk.is_file() or apk.stat().st_size < 1:
        raise ValueError("APK_MISSING")
    receipt = {"gate": "REAL_STAR_ANDROID_EMULATOR_VISUAL",
               "model_generation_verified": False,
               "geometric_star_shape_verified": False,
               "android_local_verified": False,
               "ui_color_change_verified": False,
               "apk_sha256": hashlib.sha256(apk.read_bytes()).hexdigest()}
    try:
        adb("install", "-r", str(apk))
        if "package:" not in adb("shell", "pm", "path", package):
            raise AssertionError("APK_NOT_INSTALLED")
        adb("shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1")
        time.sleep(6)
        if not adb("shell", "pidof", package).strip():
            raise AssertionError("APP_NOT_RUNNING")
        before = adb("exec-out", "screencap", "-p", binary=True)
        (out / "before.png").write_bytes(before)
        dimensions = png_pixels(before)
        x, y = dimensions[0] // 2, dimensions[1] // 2
        adb("shell", "input", "tap", str(x), str(y))
        time.sleep(2)
        after = adb("exec-out", "screencap", "-p", binary=True)
        (out / "after.png").write_bytes(after)
        metrics = compare_images(before, after)
        receipt.update(metrics)
        receipt["ui_color_change_verified"] = True
        print("CANTIERE_REAL_STAR_EMULATOR_COLOR_CHANGE_PASS " + json.dumps(metrics))
    except Exception as exc:
        receipt["failure"] = type(exc).__name__ + ": " + str(exc)
        raise
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    run(args.apk, args.package, args.out)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("CANTIERE_REAL_STAR_EMULATOR_FAIL: " + str(exc), file=sys.stderr)
        sys.exit(1)
