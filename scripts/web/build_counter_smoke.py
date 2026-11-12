#!/usr/bin/env python3
"""Generate an isolated, zero-cost static Web counter toolchain smoke.

This uses only Python stdlib. It does not authenticate users, check a real
approval, invoke AI models, or publish anything to Cloudflare Pages.
"""
import argparse
import hashlib
import json
from pathlib import Path
from zipfile import ZIP_STORED, ZipFile, ZipInfo

HTML = '''<!doctype html>
<html lang="it">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Contatore Aivexus Web — Collaudo</title>
  <link rel="stylesheet" href="styles.css">
  <script src="app.js" defer></script>
</head>
<body>
  <main class="panel">
    <p class="eyebrow">AIVEXUS WEB · COLLAUDO ISOLATO</p>
    <h1>Contatore</h1>
    <p>Incrementa o azzera il valore. Funziona anche senza Internet.</p>
    <output id="count" aria-live="polite" aria-label="Valore del contatore">0</output>
    <div class="actions">
      <button type="button" id="increment">Aggiungi 1</button>
      <button type="button" id="reset">Azzera</button>
    </div>
    <p class="note">Il valore viene salvato soltanto in questo browser.</p>
  </main>
</body>
</html>
'''
JS = """(() => {
  'use strict';
  const KEY = 'aivexus-web-counter-smoke-v1';
  const MAX = 999999;
  const display = document.getElementById('count');
  const increment = document.getElementById('increment');
  const reset = document.getElementById('reset');
  let count = 0;
  try {
    const stored = Number(localStorage.getItem(KEY));
    if (Number.isSafeInteger(stored) && stored >= 0 && stored <= MAX) {
      count = stored;
    }
  } catch (_) { /* private browsing may disable storage */ }
  const render = () => { display.textContent = String(count); };
  const persist = () => {
    try { localStorage.setItem(KEY, String(count)); }
    catch (_) { /* still usable without persistence */ }
    render();
  };
  increment.addEventListener('click', () => {
    if (count < MAX) { count += 1; }
    persist();
  });
  reset.addEventListener('click', () => { count = 0; persist(); });
  render();
})();
"""
CSS = '''* { box-sizing: border-box; }
html { color-scheme: dark; }
body { min-height: 100vh; margin: 0; display: grid; place-items: center;
  padding: 24px; background: #111827; color: #f9fafb;
  font-family: system-ui, -apple-system, sans-serif; }
.panel { width: min(100%, 520px); padding: 36px; border-radius: 20px;
  border: 1px solid #374151; background: #1f2937; text-align: center; }
.eyebrow { color: #93c5fd; letter-spacing: .12em; font-size: .73rem; }
h1 { margin: 12px 0; font-size: 2rem; }
output { display: block; font-size: clamp(4rem, 20vw, 6rem);
  font-variant-numeric: tabular-nums; padding: 14px; font-weight: 700; }
.actions { display: flex; flex-wrap: wrap; gap: 12px; justify-content: center; }
button { border: 0; border-radius: 10px; padding: 14px 20px;
  font: inherit; font-weight: 650; cursor: pointer; }
#increment { color: #111827; background: #93c5fd; }
#reset { color: #f9fafb; background: #374151; }
button:focus-visible { outline: 3px solid #fde68a; outline-offset: 3px; }
.note { color: #cbd5e1; font-size: .82rem; }
'''


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(data: object) -> bytes:
    return (json.dumps(data, sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n').encode('utf-8')


def build(output: Path) -> None:
    # Do not overwrite earlier artifacts or receipts: no durable journal yet.
    output.mkdir(parents=True, exist_ok=False)
    source = output / 'source'
    source.mkdir()
    files = {
        'index.html': HTML.encode('utf-8'),
        'app.js': JS.encode('utf-8'),
        'styles.css': CSS.encode('utf-8'),
    }
    hashes = {name: sha256(data) for name, data in files.items()}
    files['manifest.json'] = canonical_json({
        'schemaVersion': 1,
        'product': 'aivexus-web',
        'project': 'synthetic-counter-smoke',
        'sourceSha256': hashes,
    })
    for name, data in files.items():
        (source / name).write_bytes(data)
    artifact = output / 'aivexus-web-counter-smoke.zip'
    with ZipFile(artifact, 'w', compression=ZIP_STORED) as archive:
        for name, data in sorted(files.items()):
            entry = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = ZIP_STORED
            entry.external_attr = 0o644 << 16
            archive.writestr(entry, data)
    receipt = {
        'schemaVersion': 1,
        'product': 'aivexus-web',
        'project': 'synthetic-counter-smoke',
        'buildState': 'files_packaged',
        'validationState': 'separate_ci_gate_required',
        'artifactName': artifact.name,
        'artifactSha256': sha256(artifact.read_bytes()),
        'sourceSha256': hashes,
    }
    (output / 'receipt.json').write_bytes(canonical_json(receipt))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build(args.output)
