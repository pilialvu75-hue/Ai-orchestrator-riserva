import math
import struct
import unittest
import zlib

from tool.cantiere_real_star_emulator_probe import compare_images, png_pixels, star_silhouette_metrics


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


    def test_real_five_point_star_silhouette(self):
        width, height = 120, 160
        before = png(width, height, lambda x, y: (0, 0, 0))

        def changed_star(x, y):
            dx, dy = x - width / 2, y - height / 2
            theta = math.atan2(dy, dx)
            radius = math.hypot(dx, dy)
            return radius <= 30 * (0.68 + 0.32 * math.cos(5 * (theta - math.pi / 2)))

        after = png(width, height, lambda x, y: (255, 0, 0) if changed_star(x, y) else (0, 0, 0))
        metrics = star_silhouette_metrics(before, after)
        self.assertGreater(metrics["five_point_harmonic"], metrics["four_point_harmonic"] * 1.3)

    def test_rectangle_color_change_not_a_star(self):
        before = png(120, 160, lambda x, y: (0, 0, 0))
        after = png(120, 160, lambda x, y: (255, 0, 0) if 30 <= x <= 90 and 55 <= y <= 105 else (0, 0, 0))
        compare_images(before, after)  # Existing color-only gate would accept it.
        with self.assertRaisesRegex(AssertionError, "FIVE_POINT_STAR_GEOMETRY"):
            star_silhouette_metrics(before, after)

    def test_circle_color_change_not_a_star(self):
        before = png(120, 160, lambda x, y: (0, 0, 0))
        after = png(120, 160, lambda x, y: (255, 0, 0) if (x-60)**2 + (y-80)**2 <= 26**2 else (0, 0, 0))
        with self.assertRaisesRegex(AssertionError, "FIVE_POINT_STAR_GEOMETRY"):
            star_silhouette_metrics(before, after)

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
