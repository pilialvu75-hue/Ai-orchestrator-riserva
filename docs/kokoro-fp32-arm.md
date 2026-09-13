# Kokoro FP32 candidate — 2026-09-13

Phone diagnostics on build 1671 still show non_finite_pcm with the pinned INT8 bundle before playback. Upstream report https://github.com/k2-fsa/sherpa-onnx/issues/3754 describes ARM-specific INT8 corruption with FP32 unaffected in those tests. This is supporting evidence, not proof of the identical root cause on S24 FE.

Switch the downloadable package to official Kokoro v1.0 FP32 (349906910 bytes). Archive SHA-256 comes from the upstream GitHub release asset; model, voices and tokens hashes were independently measured on ARM64 and x86 after archive verification. The new directory and archive identity prevent an existing INT8 installation from passing as FP32. Old assets remain untouched. Download requires the existing user action in voice-model settings; the UI shows ~350 MB.

The native CI job generates real Italian, French and English speech using sherpa-onnx 1.13.6 on Linux ARM64 and x86. It verifies nonempty, finite and non-silent PCM at 24 kHz. Linux ARM64 is not Android: phone acceptance remains mandatory. No invalid PCM is zeroed or sent to playback.

After the containing main release is published, install without uninstalling, download Kokoro FP32 in voice models, and test one short Italian answer via the speaker. Then check French and English. Require audible speech and TTS_AUDIO_READY without non_finite_pcm. Live/STT latency and local LLM crashes remain separate.
