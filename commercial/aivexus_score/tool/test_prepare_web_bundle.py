from pathlib import Path
from tempfile import TemporaryDirectory
import json
import unittest

from prepare_web_bundle import LOCAL_RENDERER, prepare


class PrepareWebBundleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "canvaskit").mkdir()
        (self.root / "canvaskit" / "canvaskit.js").write_text("renderer")
        (self.root / "canvaskit" / "canvaskit.wasm").write_bytes(b"wasm")
        (self.root / "index.html").write_text(
            '<base href="/"><title>aivexus_score</title>'
            '<meta name="description" content="A new Flutter project.">'
        )
        (self.root / "manifest.json").write_text(
            json.dumps({"name": "aivexus_score", "start_url": "/"})
        )
        (self.root / "flutter_bootstrap.js").write_text(
            "_flutter.loader.load({\n  serviceWorkerSettings: {}\n});\n"
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_rewrites_relative_paths_and_local_renderer(self) -> None:
        prepare(self.root)
        html = (self.root / "index.html").read_text()
        self.assertIn('<base href="./">', html)
        self.assertIn("<title>AIVEXUS Score</title>", html)
        self.assertNotIn("A new Flutter project", html)
        bootstrap = (self.root / "flutter_bootstrap.js").read_text()
        self.assertEqual(bootstrap.count(LOCAL_RENDERER), 1)
        manifest = json.loads((self.root / "manifest.json").read_text())
        self.assertEqual(manifest["name"], "AIVEXUS Score")
        self.assertEqual(manifest["start_url"], ".")

    def test_idempotent(self) -> None:
        prepare(self.root)
        before = (self.root / "flutter_bootstrap.js").read_text()
        prepare(self.root)
        self.assertEqual((self.root / "flutter_bootstrap.js").read_text(), before)

    def test_missing_renderer_stops_packaging(self) -> None:
        (self.root / "canvaskit" / "canvaskit.wasm").unlink()
        with self.assertRaisesRegex(ValueError, "Missing essential"):
            prepare(self.root)

    def test_unrecognized_loader_stops_packaging(self) -> None:
        (self.root / "flutter_bootstrap.js").write_text("unknown bootstrap")
        with self.assertRaisesRegex(ValueError, "Unknown Flutter loader"):
            prepare(self.root)


if __name__ == "__main__":
    unittest.main()
