import struct
import unittest
import zlib

from tool.cantiere_real_star_emulator_probe import compare_images, png_pixels


def png(width, height, data):
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + b"".join(bytes(data(x, y)) for x in range(width)) for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class RealStarScreenshotGateTests(unittest.TestCase):
    def test_dark_canvas_and_center_color_change(self):
        before = png(90, 120, lambda x, y: (0, 0, 0))
        after = png(90, 120, lambda x, y: (255, 0, 0) if 40 <= x < 50 and 52 <= y < 64 else (0, 0, 0))
        result = compare_images(before, after)
        self.assertGreater(result["changed_ratio"], 0.006)
        self.assertTrue(png_pixels(after)[0] == 90)

    def test_peripheral_change_fails_central_gate(self):
        before = png(96, 128, lambda x, y: (0, 0, 0))
        # Changed area lies in tested canvas but outside the inner center.
        after = png(96, 128, lambda x, y: (255, 0, 0) if 18 < x < 30 and 52 <= y < 67 else (0, 0, 0))
        with self.assertRaisesRegex(AssertionError, "COLOR_CHANGE"):
            compare_images(before, after)

    def test_static_screen_fails(self):
        screenshot = png(60, 90, lambda x, y: (0, 0, 0))
        with self.assertRaisesRegex(AssertionError, "COLOR_CHANGE"):
            compare_images(screenshot, screenshot)

    def test_white_background_fails(self):
        before = png(60, 90, lambda x, y: (255, 255, 255))
        after = png(60, 90, lambda x, y: (255, 0, 0) if 20 < x < 30 else (255, 255, 255))
        with self.assertRaisesRegex(AssertionError, "NOT_DARK"):
            compare_images(before, after)


if __name__ == "__main__":
    unittest.main()
