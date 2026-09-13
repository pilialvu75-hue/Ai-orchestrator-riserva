"""Verify the pinned Kokoro FP32 bundle and real IT/FR/EN synthesis."""
import hashlib
import json
import pathlib
import platform
import tarfile
import tempfile
import urllib.request

import numpy as np
import sherpa_onnx

URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2"
SHA256 = "c5f7e2d2caf082bc1d20fb70334a61d99d20b484500aad32e7cf84c128ea3298"
SIZE = 349906910

def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

with tempfile.TemporaryDirectory() as work:
    root = pathlib.Path(work)
    archive = root / "kokoro.tar.bz2"
    urllib.request.urlretrieve(URL, archive)
    assert archive.stat().st_size == SIZE
    assert digest(archive) == SHA256
    with tarfile.open(archive) as bundle:
        bundle.extractall(root / "payload", filter="data")
    model = next((root / "payload").rglob("model.onnx"))
    folder = model.parent
    for name in ("model.onnx", "voices.bin", "tokens.txt"):
        print("PAYLOAD_HASH", name, digest(folder / name), flush=True)
    tts = sherpa_onnx.OfflineTts(sherpa_onnx.OfflineTtsConfig(
        model=sherpa_onnx.OfflineTtsModelConfig(
            kokoro=sherpa_onnx.OfflineTtsKokoroModelConfig(
                model=str(model), voices=str(folder / "voices.bin"),
                tokens=str(folder / "tokens.txt"),
                data_dir=str(folder / "espeak-ng-data"), lang="it"),
            num_threads=1, provider="cpu", debug=False),
        max_num_sentences=1))
    for lang, sid, text in (
        ("it", 35, "Ciao, come stai?"),
        ("fr", 30, "Bonjour, comment allez-vous?"),
        ("en", 3, "Hello, how are you?"),
    ):
        config = sherpa_onnx.GenerationConfig(sid=sid, speed=1.0)
        config.extra = {"lang": lang}
        audio = tts.generate(text, config)
        samples = np.asarray(audio.samples)
        assert samples.size > 0 and audio.sample_rate == 24000
        assert np.isfinite(samples).all(), lang
        rms = float(np.sqrt(np.mean(samples.astype(np.float64) ** 2)))
        assert rms > 0.00001, lang
        print("SYNTHESIS_OK", json.dumps(dict(arch=platform.machine(),
              lang=lang, sid=sid, samples=int(samples.size), rms=rms)), flush=True)
