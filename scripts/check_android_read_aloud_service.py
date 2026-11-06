#!/usr/bin/env python3
"""Android 17 read-aloud lifecycle regression contract, no device needed.

Source contract only: it does not certify that Bluetooth, background, lock
screen or 10-second seek actually work on a physical Android 17 device.
"""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
AND = "{http://schemas.android.com/apk/res/android}"


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def validate() -> list[str]:
    problems: list[str] = []
    manifest = ET.fromstring(read("android/app/src/main/AndroidManifest.xml"))
    permissions = {node.attrib.get(AND + "name")
                   for node in manifest.findall("uses-permission")}
    for permission in (
        "android.permission.FOREGROUND_SERVICE",
        "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK",
    ):
        if permission not in permissions:
            problems.append("Missing Android 17 foreground permission " + permission)

    services = [node for node in manifest.find("application").findall("service")
                if node.attrib.get(AND + "name") == ".PcmReadAloudMediaService"]
    if len(services) != 1:
        problems.append("Exactly one read-aloud service is required")
    elif (services[0].attrib.get(AND + "foregroundServiceType") != "mediaPlayback"
          or services[0].attrib.get(AND + "exported") != "false"):
        problems.append("Read-aloud service must be non-exported mediaPlayback FGS")

    activity = read("android/app/src/main/kotlin/com/aiorchestrator/MainActivity.kt")
    if "PcmReadAloudBridge.register(applicationContext, flutterEngine)" not in activity:
        problems.append("Flutter PCM bridge must be registered")
    if "pcmReadAloud?.close()" in activity or "private var pcmReadAloud:" in activity:
        problems.append("MainActivity must not own or close background PCM playback")

    service = read("android/app/src/main/kotlin/com/aiorchestrator/PcmReadAloudMediaService.kt")
    bridge = read("android/app/src/main/kotlin/com/aiorchestrator/PcmReadAloudBridge.kt")
    service_markers = (
        "ContextCompat.startForegroundService",
        "startForeground(NOTIFICATION_ID",
        "MediaSession(this,",
        "Notification.MediaStyle()",
        "AudioFocusRequest.Builder(",
        "override fun onPlay()",
        "override fun onPause()",
        "override fun onSeekTo(",
        "override fun onRewind()",
        "override fun onFastForward()",
        "transport.close()",
        "return START_NOT_STICKY",
        "setShowActionsInCompactView",
        "setOnAudioFocusChangeListener",
        "AudioManager.ACTION_AUDIO_BECOMING_NOISY",
        "registerReceiver(becomingNoisy, noisyFilter",
        "unregisterReceiver(becomingNoisy)",
        "Context.RECEIVER_NOT_EXPORTED",
    )
    bridge_markers = (
        "PcmReadAloudMediaService.ensureStarted(app)",
        "PcmReadAloudMediaService.active()",
        '"prepare" ->',
        '"pause" ->',
        '"resume" ->',
        '"seekRelative" ->',
        '"stop", "dispose" ->',
    )
    for marker in service_markers:
        if marker not in service:
            problems.append("Missing foreground service contract: " + marker)
    for marker in bridge_markers:
        if marker not in bridge and not (marker == '"prepare" ->'
                                         and 'call.method == "prepare"' in bridge):
            problems.append("Missing service-backed channel: " + marker)
    if "val transport = PcmReadAloudBridge(context.applicationContext)" in bridge:
        problems.append("MethodChannel must never own a second PCM player")

    # Protect the existing fully offline Kokoro/STT implementation.
    voice = read("lib/core/voice/isolated_kokoro_voice_engine.dart")
    if "await readAloud?.beginReadAloud()" not in voice:
        problems.append("Offline TTS must begin the user-started service")
    if "await readAloud?.finishReadAloud()" not in voice:
        problems.append("Offline TTS must mark PCM complete")
    if "await readAloud?.stopReadAloud()" not in voice:
        problems.append("Failed/no-model TTS must stop foreground playback")
    return problems


def main() -> int:
    errors = validate()
    for error in errors:
        print("::error::" + error, file=sys.stderr)
    if errors:
        return 1
    print("Android 17 read-aloud service ownership and permissions: contract OK")
    print("Physical S24 FE background/media-focus testing still required.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
