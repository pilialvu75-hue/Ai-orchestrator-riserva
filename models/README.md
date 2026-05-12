# models/

Pre-trained and fine-tuned AI model files (GGUF format and metadata).

This directory is the designated location for storing locally bundled AI model files
that are shipped with the application or downloaded by users.

## Contents

- `*.gguf` — Quantised GGUF model weights (excluded from git via `.gitignore`)
- `manifest.json` — Version registry metadata describing available bundled models

> Large binary model files (`.gguf`) are excluded from version control.
> See `lib/core/config/app/app_constants.dart` for the model registry and download URLs.
