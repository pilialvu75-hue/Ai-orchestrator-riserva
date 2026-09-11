# Kokoro payload verification — 2026-09-11

The S24 FE on build 1618 reports `TTS_FAIL error=non_finite_pcm`.
This occurs before AudioStreamPlayer. The root cause of the old phone
payload's numerical failure is not yet proven.

The upstream release URL is mutable. Its current archive is 132303094 bytes,
SHA-256 `4c3052abaa60943a341f193888cf6abd68787dae6ab8ae5c925a706caa247e4e`.
The app previously pinned a different archive (131839838 bytes). Updating
only the application cannot replace an already installed voice package.

This change pins the refreshed official archive and independent hashes of
model.int8.onnx, voices.bin and tokens.txt. Verification rejects an old
manifest and rejects even self-consistent local hashes of an incorrect
payload. Archive verification and atomic replacement remain in place.
No automatic download is introduced: download Kokoro again through the
existing voice-model controls after installing the released APK.

## Native synthesis check

Executed on Linux x86_64 with Python sherpa-onnx 1.13.6, CPU provider,
one thread, max_num_sentences=1, Italian initialization language and
per-request language overrides, speed=1.0:

| Language / speaker | Text | Samples | Finite samples | Peak |
| --- | --- | ---: | ---: | ---: |
| it / 35 | Ciao, come stai? | 30720 | 30720 | 0.831364 |
| fr / 30 | Bonjour, comment allez-vous? | 35036 | 35036 | 0.457679 |
| en / 3 | Hello, how are you? | 26087 | 26087 | 0.322449 |

The model was read directly from the verified archive and its SHA-256 checked.
The Dart SDK implementation copies PCM before freeing native audio, so no
evidence currently supports a use-after-free diagnosis in the app's worker.

These checks establish that the refreshed payload can synthesize finite,
nonzero PCM. They do not prove Android correctness, audible speaker output,
or that the previous package was the sole cause of the phone failure.

## Phone acceptance

Install the main release APK containing this change, without uninstalling.
Download the refreshed Kokoro package (about 132 MB), then tap the speaker
once on a short Italian response. Require TTS_AUDIO_READY and valid PCM plus
audible speech. Repeat in French and English. If non_finite_pcm persists
with the pinned payload, investigate ARM64/runtime numerical behavior;
do not remove PCM validation or replace invalid samples with silence.

Live conversation persistence, subtitles and latency remain separate work.
