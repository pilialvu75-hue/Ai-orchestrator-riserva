package com.aiorchestrator

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Main Android activity for AI-Orchestrator.
 *
 * Bridges Android [Intent] data to the Flutter layer via a [MethodChannel].
 *
 * Channel name: "com.aiorchestrator/android_intents"
 *
 * Methods handled from Flutter:
 *   - shareContext(context: String)   → broadcasts a SHARE_CONTEXT intent
 *   - sendCodeSnippet(snippet: String)→ broadcasts a RECEIVE_CODE intent
 *   - getIncomingIntentData()         → returns the payload of the launching
 *                                       intent, if any
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.aiorchestrator/android_intents"
    private val sherpaVoiceChannelName = "com.aiorchestrator/sherpa_onnx_voice"
    private val sherpaAsrEventsChannelName = "com.aiorchestrator/sherpa_onnx_asr_events"
    private val mlcNativeChannelName = "com.aiorchestrator/mlc_native"
    private val logTag = "AO_UPDATE"
    private val apkInstallRequestCode = 9917
    private val sherpaLibraryGroups = listOf(
        listOf("onnxruntime", "sherpa-onnx-jni"),
        listOf("onnxruntime", "sherpa-onnx"),
        listOf("onnxruntime4j_jni", "sherpa-onnx-jni"),
        listOf("onnxruntime", "sherpa_onnx_jni")
    )
    private var pendingIntentData: Map<String, Any?>? = null
    private var lastInstallerLaunchSuccess: Boolean? = null
    private var lastInstallerException: String? = null
    private var lastInstallerResultCode: Int? = null
    private var sherpaLibrariesChecked = false
    private var sherpaLibrariesLoaded = false
    private var sherpaLibraryError: String? = null

    // ── Lifecycle ──────────────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerIntentChannel(flutterEngine)
        registerSherpaVoiceChannels(flutterEngine)
        registerMlcNativeChannel(flutterEngine)
        extractIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        extractIncomingIntent(intent)
    }

    // ── MethodChannel registration ─────────────────────────────────────────

    private fun registerIntentChannel(engine: FlutterEngine) {
        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "shareContext" -> {
                    val context = call.argument<String>("context") ?: ""
                    broadcastIntent(
                        action = "com.aiorchestrator.SHARE_CONTEXT",
                        extras = mapOf("context" to context)
                    )
                    result.success(null)
                }

                "sendCodeSnippet" -> {
                    val snippet = call.argument<String>("snippet") ?: ""
                    broadcastIntent(
                        action = "com.aiorchestrator.RECEIVE_CODE",
                        extras = mapOf("snippet" to snippet)
                    )
                    result.success(null)
                }

                "getIncomingIntentData" -> {
                    result.success(pendingIntentData)
                    pendingIntentData = null   // consume once
                }

                "openApkInstaller" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "apkPath is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        Log.i(logTag, "[INSTALL] openApkInstaller requested path=$apkPath")
                        val apkFile = File(apkPath)
                        if (!apkFile.exists()) {
                            lastInstallerLaunchSuccess = false
                            lastInstallerException = "APK file not found at $apkPath"
                            result.error("FILE_NOT_FOUND", "APK file not found", null)
                            return@setMethodCallHandler
                        }
                        Log.i(logTag, "[APK] APK exists=${apkFile.exists()} size=${apkFile.length()} path=${apkFile.absolutePath}")

                        val canInstallPackages = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            packageManager.canRequestPackageInstalls()
                        } else {
                            true
                        }
                        Log.i(logTag, "[INSTALL] canRequestPackageInstalls=$canInstallPackages sdk=${Build.VERSION.SDK_INT}")
                        if (!canInstallPackages) {
                            openUnknownAppsSettingsInternal()
                            lastInstallerLaunchSuccess = false
                            lastInstallerException = "Unknown apps install permission denied"
                            result.error(
                                "UNKNOWN_APPS_PERMISSION_DENIED",
                                "Allow install from unknown apps for AI Orchestrator, then retry.",
                                null
                            )
                            return@setMethodCallHandler
                        }

                        val apkUri = FileProvider.getUriForFile(
                            this,
                            "${packageName}.fileprovider",
                            apkFile
                        )
                        Log.i(logTag, "[APK] Using FileProvider content URI: $apkUri")
                        val installIntent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(apkUri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        val resolved = installIntent.resolveActivity(packageManager)
                        Log.i(logTag, "[INSTALL] Installer resolveActivity=${resolved?.flattenToShortString()}")
                        if (resolved == null) {
                            lastInstallerLaunchSuccess = false
                            lastInstallerException = "No package installer activity found"
                            result.error("INSTALLER_NOT_FOUND", "No package installer available", null)
                            return@setMethodCallHandler
                        }
                        startActivityForResult(installIntent, apkInstallRequestCode)
                        lastInstallerLaunchSuccess = true
                        lastInstallerException = null
                        Log.i(logTag, "[INSTALL] Installer intent launched successfully")
                        result.success(true)
                    } catch (e: Exception) {
                        lastInstallerLaunchSuccess = false
                        lastInstallerException = "Failed to launch installer: ${e.message}"
                        Log.e(logTag, "[INSTALL] Failed to launch installer", e)
                        result.error(
                            "INSTALL_ERROR",
                            "Failed to create FileProvider URI or launch installer: ${e.message}",
                            null
                        )
                    }
                }

                "openUnknownAppsSettings" -> {
                    try {
                        openUnknownAppsSettingsInternal()
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(logTag, "[INSTALL] Failed to open unknown-apps settings", e)
                        result.error(
                            "UNKNOWN_APPS_SETTINGS_ERROR",
                            "Failed to open unknown apps settings: ${e.message}",
                            null
                        )
                    }
                }

                "getInstallDiagnostics" -> {
                    val canInstallPackages = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        packageManager.canRequestPackageInstalls()
                    } else {
                        true
                    }
                    result.success(
                        mapOf(
                            "sdkInt" to Build.VERSION.SDK_INT,
                            "canRequestPackageInstalls" to canInstallPackages,
                            "lastInstallerLaunchSuccess" to lastInstallerLaunchSuccess,
                            "lastInstallerException" to lastInstallerException,
                            "lastInstallerResultCode" to lastInstallerResultCode,
                        )
                    )
                }

                "persistDocumentUriPermission" -> {
                    val rawUri = call.argument<String>("uri")
                    if (rawUri.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "uri is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = Uri.parse(rawUri)
                        contentResolver.takePersistableUriPermission(
                            uri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION
                        )
                        result.success(rawUri)
                    } catch (securityError: SecurityException) {
                        result.success(rawUri)
                    } catch (e: Exception) {
                        result.error(
                            "URI_PERMISSION_ERROR",
                            "Failed to persist URI permission: ${e.message}",
                            null
                        )
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun registerSherpaVoiceChannels(engine: FlutterEngine) {
        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            sherpaVoiceChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "initializeSherpaOnnx" -> {
                    result.success(buildSherpaStatus())
                }
                "getSherpaStatus" -> result.success(buildSherpaStatus())
                "startAsr", "stopAsr", "speakTts", "stopTts" -> {
                    if (!ensureSherpaLibrariesLoaded()) {
                        result.error(
                            "SHERPA_NOT_AVAILABLE",
                            sherpaLibraryError ?: "Sherpa-ONNX libraries are unavailable in this build.",
                            buildSherpaStatus()
                        )
                        return@setMethodCallHandler
                    }
                    result.error(
                        "SHERPA_NOT_IMPLEMENTED",
                        "Sherpa-ONNX native audio session wiring is not configured in this build.",
                        buildSherpaStatus(initialized = true)
                    )
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            engine.dartExecutor.binaryMessenger,
            sherpaAsrEventsChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                // Stream hook reserved for native Sherpa ASR partial/final events.
            }

            override fun onCancel(arguments: Any?) {
                // No-op placeholder.
            }
        })
    }

    private fun buildSherpaStatus(initialized: Boolean = false): Map<String, Any?> {
        val audioManager = getSystemService(AUDIO_SERVICE) as? AudioManager
        val hasAudioOutputs = if (audioManager == null) {
            false
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).isNotEmpty()
        } else {
            true
        }
        val librariesLoaded = ensureSherpaLibrariesLoaded()
        return mapOf(
            "engineId" to "sherpa-onnx",
            "supportedPlatform" to true,
            "nativeLibrariesLoaded" to librariesLoaded,
            "microphonePermissionGranted" to (
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.RECORD_AUDIO
                ) == PackageManager.PERMISSION_GRANTED
            ),
            "audioSessionReady" to (audioManager != null),
            "speakerOutputReady" to hasAudioOutputs,
            "initialized" to (initialized && librariesLoaded),
            "offlineAsrAvailable" to librariesLoaded,
            "offlineTtsAvailable" to librariesLoaded,
            "details" to sherpaLibraryError
        )
    }

    private fun ensureSherpaLibrariesLoaded(): Boolean {
        if (sherpaLibrariesChecked) {
            return sherpaLibrariesLoaded
        }
        sherpaLibrariesChecked = true
        val failures = mutableListOf<String>()
        val nativeLibraryDirectory = File(applicationInfo.nativeLibraryDir)
        for (group in sherpaLibraryGroups) {
            val missingLibraries = group.filterNot { libraryName ->
                File(nativeLibraryDirectory, System.mapLibraryName(libraryName)).exists()
            }
            if (missingLibraries.isNotEmpty()) {
                failures += "${group.joinToString("+")}: missing ${missingLibraries.joinToString(",")}"
                continue
            }
            val groupFailures = mutableListOf<String>()
            for (libraryName in group) {
                try {
                    System.loadLibrary(libraryName)
                } catch (error: Throwable) {
                    groupFailures += "$libraryName: ${error.message}"
                    break
                }
            }
            if (groupFailures.isEmpty()) {
                sherpaLibrariesLoaded = true
                sherpaLibraryError = null
                break
            }
            failures += "${group.joinToString("+")}: ${groupFailures.joinToString(" | ")}"
        }
        if (!sherpaLibrariesLoaded) {
            sherpaLibraryError = failures.joinToString(" | ").ifBlank {
                "Sherpa-ONNX runtime libraries could not be loaded."
            }
        }
        return sherpaLibrariesLoaded
    }

    private fun registerMlcNativeChannel(engine: FlutterEngine) {
        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            mlcNativeChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isMlcNativeAvailable" -> result.success(MlcNativeBridge.isAvailable())
                "getMlcBackend" -> result.success(MlcNativeBridge.backendName())
                "getMlcRuntimeDiagnostics" -> result.success(MlcNativeBridge.diagnostics())
                else -> result.notImplemented()
            }
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    /**
     * Sends a broadcast [Intent] with the given [action] and optional [extras].
     */
    private fun broadcastIntent(action: String, extras: Map<String, String>) {
        val intent = Intent(action).apply {
            extras.forEach { (key, value) -> putExtra(key, value) }
        }
        sendBroadcast(intent)
    }

    /**
     * Parses an incoming [Intent] and stores any relevant payload so that
     * Flutter can retrieve it via [getIncomingIntentData].
     */
    private fun extractIncomingIntent(intent: Intent?) {
        intent ?: return
        val data = mutableMapOf<String, Any?>()

        when (intent.action) {
            Intent.ACTION_SEND -> {
                intent.getStringExtra(Intent.EXTRA_TEXT)?.let {
                    data["text"] = it
                    data["action"] = "android.intent.action.SEND"
                }
            }
            "com.aiorchestrator.SHARE_CONTEXT" -> {
                intent.getStringExtra("context")?.let {
                    data["context"] = it
                    data["action"] = intent.action
                }
            }
            "com.aiorchestrator.RECEIVE_CODE" -> {
                intent.getStringExtra("snippet")?.let {
                    data["snippet"] = it
                    data["action"] = intent.action
                }
            }
        }

        if (data.isNotEmpty()) {
            pendingIntentData = data
        }
    }

    private fun openUnknownAppsSettingsInternal() {
        val settingsIntent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName")
        ).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        Log.i(logTag, "[INSTALL] Opening unknown-apps settings for package=$packageName")
        startActivity(settingsIntent)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == apkInstallRequestCode) {
            lastInstallerResultCode = resultCode
            Log.i(logTag, "[INSTALL] Installer activity resultCode=$resultCode")
        }
    }
}
