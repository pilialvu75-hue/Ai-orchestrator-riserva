package com.aiorchestrator

import android.Manifest
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.content.pm.PackageManager
import android.media.AudioManager
import android.content.Intent
import android.content.ClipData
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.util.Locale
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
    private val voiceAudioFocusChannelName = "com.aiorchestrator/audio_focus"
    private val logTag = "AO_UPDATE"
    private val hashBufferSizeBytes = 32 * 1024
    private val apkInstallRequestCode = 9917
    // Native Sherpa/ONNX builds use different shared-library names depending on
    // packaging strategy; probe the most common combinations in priority order.
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
    private val voiceAudioFocusChangeListener =
        AudioManager.OnAudioFocusChangeListener { /* observational only */ }
    private var voiceAudioFocusRequest: AudioFocusRequest? = null

    // ── Lifecycle ──────────────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerIntentChannel(flutterEngine)
        registerSherpaVoiceChannels(flutterEngine)
        registerMlcNativeChannel(flutterEngine)
        registerVoiceAudioFocusChannel(flutterEngine)
        extractIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        extractIncomingIntent(intent)
    }

    override fun onDestroy() {
        releaseVoiceAudioFocus()
        super.onDestroy()
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
                        Log.i(logTag, "[UPDATE_INSTALL_BEGIN] apk_path=$apkPath")
                        Log.i(logTag, "[UPDATE_INSTALL_START] path=$apkPath")
                        val apkFile = File(apkPath)
                        if (!apkFile.exists()) {
                            lastInstallerLaunchSuccess = false
                            lastInstallerException = "APK file not found at $apkPath"
                            Log.e(logTag, "[UPDATE_INSTALL_FAIL] reason=apk_file_missing")
                            Log.e(logTag, "[UPDATE_INSTALL_RESULT] success=false reason=apk_file_missing")
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
                            Log.e(logTag, "[UPDATE_INSTALL_FAIL] reason=unknown_apps_permission_denied")
                            Log.e(logTag, "[UPDATE_INSTALL_RESULT] success=false reason=unknown_apps_permission_denied")
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
                        val installIntent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                            setDataAndType(apkUri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
                            putExtra(Intent.EXTRA_RETURN_RESULT, true)
                            clipData = ClipData.newUri(contentResolver, "apk", apkUri)
                        }
                        val resolved = installIntent.resolveActivity(packageManager)
                        Log.i(logTag, "[INSTALL] Installer resolveActivity=${resolved?.flattenToShortString()}")
                        if (resolved == null) {
                            lastInstallerLaunchSuccess = false
                            lastInstallerException = "No package installer activity found"
                            Log.e(logTag, "[UPDATE_INSTALL_FAIL] reason=installer_not_found")
                            Log.e(logTag, "[UPDATE_INSTALL_RESULT] success=false reason=installer_not_found")
                            result.error("INSTALLER_NOT_FOUND", "No package installer available", null)
                            return@setMethodCallHandler
                        }
                        val resolvedActivities = packageManager.queryIntentActivities(
                            installIntent,
                            PackageManager.MATCH_DEFAULT_ONLY
                        )
                        resolvedActivities.forEach { activityInfo ->
                            grantUriPermission(
                                activityInfo.activityInfo.packageName,
                                apkUri,
                                Intent.FLAG_GRANT_READ_URI_PERMISSION
                            )
                        }
                        lastInstallerResultCode = null
                        startActivityForResult(installIntent, apkInstallRequestCode)
                        lastInstallerLaunchSuccess = true
                        lastInstallerException = null
                        Log.i(logTag, "[INSTALL] Installer intent launched successfully")
                        Log.i(logTag, "[UPDATE_INSTALL_SUCCESS] launched=true")
                        Log.i(logTag, "[UPDATE_INSTALL_RESULT] success=true launched=true")
                        result.success(true)
                    } catch (e: Exception) {
                        lastInstallerLaunchSuccess = false
                        lastInstallerException = "Failed to launch installer: ${e.message}"
                        Log.e(logTag, "[INSTALL] Failed to launch installer", e)
                        Log.e(logTag, "[UPDATE_INSTALL_FAIL] reason=exception message=${e.message}")
                        Log.e(logTag, "[UPDATE_INSTALL_RESULT] success=false reason=exception message=${e.message}")
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
                    val installedPackageInfo = getInstalledPackageInfo()
                    result.success(
                        mapOf(
                            "sdkInt" to Build.VERSION.SDK_INT,
                            "canRequestPackageInstalls" to canInstallPackages,
                            "lastInstallerLaunchSuccess" to lastInstallerLaunchSuccess,
                            "lastInstallerException" to lastInstallerException,
                            "lastInstallerResultCode" to lastInstallerResultCode,
                            "installerPackageName" to getInstallerPackageName(),
                            "applicationId" to packageName,
                            "installedVersionName" to installedPackageInfo.versionName,
                            "installedVersionCode" to getVersionCode(installedPackageInfo),
                            "installedSignatureSha256" to extractSignatureSha256(installedPackageInfo),
                        )
                    )
                }

                "verifyApk" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "apkPath is required", null)
                        return@setMethodCallHandler
                    }
                    result.success(verifyApkInternal(apkPath))
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
                        buildSherpaStatus(isInitialized = true)
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

    private fun buildSherpaStatus(isInitialized: Boolean = false): Map<String, Any?> {
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
            "initialized" to (isInitialized && librariesLoaded),
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
            sherpaLibraryError = if (failures.isEmpty()) {
                "Sherpa-ONNX runtime libraries could not be loaded."
            } else {
                "Sherpa-ONNX fallback groups attempted: ${failures.joinToString(" | ")}"
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

        private fun registerVoiceAudioFocusChannel(engine: FlutterEngine) {
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                voiceAudioFocusChannelName
            ).setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireVoiceFocus" -> result.success(requestVoiceAudioFocus())
                    "releaseVoiceFocus" -> {
                        releaseVoiceAudioFocus()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        private fun requestVoiceAudioFocus(): Boolean {
            val audioManager = getSystemService(AUDIO_SERVICE) as? AudioManager ?: return false
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (voiceAudioFocusRequest == null) {
                    voiceAudioFocusRequest = AudioFocusRequest.Builder(
                        AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                    )
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_ASSISTANT)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                .build()
                        )
                        .setAcceptsDelayedFocusGain(false)
                        .setWillPauseWhenDucked(false)
                        .setOnAudioFocusChangeListener(voiceAudioFocusChangeListener)
                        .build()
                }
                audioManager.requestAudioFocus(voiceAudioFocusRequest!!) ==
                    AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(
                    voiceAudioFocusChangeListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            }
        }

        private fun releaseVoiceAudioFocus() {
            val audioManager = getSystemService(AUDIO_SERVICE) as? AudioManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                voiceAudioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(voiceAudioFocusChangeListener)
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

    private fun verifyApkInternal(apkPath: String): Map<String, Any?> {
        val apkFile = File(apkPath)
        val exists = apkFile.exists()
        val sizeBytes = if (exists) apkFile.length() else 0L
        val readable = exists && apkFile.canRead()
        val hasApkExtension = apkFile.name.lowercase(Locale.ROOT).endsWith(".apk")
        val inferredAbi = inferAbi(apkFile.name)
        val fileSha256 = if (exists && readable) calculateFileSha256(apkFile) else null
        val packageInfo = if (exists && readable && hasApkExtension) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageArchiveInfo(
                    apkPath,
                    PackageManager.PackageInfoFlags.of(archiveInfoFlags().toLong())
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageArchiveInfo(apkPath, archiveInfoFlags())
            }
        } else {
            null
        }
        val packageName = packageInfo?.packageName
        val versionName = packageInfo?.versionName
        val versionCode = packageInfo?.let { getVersionCode(it) }
        val signatureSha256 = packageInfo?.let { extractSignatureSha256(it) }
        val hasSplitConfig = hasSplitConfiguration(apkFile.name, packageInfo)
        val archiveParsed = packageInfo != null
        Log.i(
            logTag,
            "[UPDATE_APK_ANALYSIS] apk_filename=${apkFile.name} abi=${inferredAbi ?: "-"} split_config_present=$hasSplitConfig package_archive_info=$archiveParsed"
        )
        return mapOf(
            "valid" to (
                exists &&
                    readable &&
                    hasApkExtension &&
                    sizeBytes > 0 &&
                    packageName != null &&
                    !hasSplitConfig
                ),
            "exists" to exists,
            "readable" to readable,
            "hasApkExtension" to hasApkExtension,
            "sizeBytes" to sizeBytes,
            "packageName" to packageName,
            "versionName" to versionName,
            "versionCode" to versionCode,
            "signatureSha256" to signatureSha256,
            "fileSha256" to fileSha256,
            "hasSplitConfig" to hasSplitConfig,
            "abi" to inferredAbi,
            "archiveParsed" to archiveParsed,
            "reason" to when {
                !exists -> "missing"
                !readable -> "not_readable"
                !hasApkExtension -> "invalid_extension"
                sizeBytes <= 0 -> "empty_file"
                packageName == null -> "package_parse_failed"
                hasSplitConfig -> "split_apk_unsupported"
                else -> "ok"
            }
        )
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == apkInstallRequestCode) {
            lastInstallerResultCode = resultCode
            Log.i(logTag, "[INSTALL] Installer activity resultCode=$resultCode")
            Log.i(logTag, "[UPDATE_INSTALL_RESULT] success=${resultCode == RESULT_OK} result_code=$resultCode")
        }
    }

    private fun getInstalledPackageInfo() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        packageManager.getPackageInfo(
            packageName,
            PackageManager.PackageInfoFlags.of(archiveInfoFlags().toLong())
        )
    } else {
        @Suppress("DEPRECATION")
        packageManager.getPackageInfo(packageName, archiveInfoFlags())
    }

    private fun getInstallerPackageName(): String? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            packageManager.getInstallSourceInfo(packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            packageManager.getInstallerPackageName(packageName)
        }
    } catch (_: Exception) {
        null
    }

    private fun archiveInfoFlags(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
    }

    private fun getVersionCode(packageInfo: android.content.pm.PackageInfo): Long {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toLong()
        }
    }

    private fun extractSignatureSha256(packageInfo: android.content.pm.PackageInfo): String? {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = packageInfo.signingInfo ?: return null
            if (signingInfo.hasMultipleSigners()) {
                signingInfo.apkContentsSigners
            } else {
                signingInfo.signingCertificateHistory
            }
        } else {
            @Suppress("DEPRECATION")
            packageInfo.signatures
        }
        val first = signatures?.firstOrNull() ?: return null
        val digest = MessageDigest.getInstance("SHA-256").digest(first.toByteArray())
        return digest.joinToString(":") { "%02X".format(it) }
    }

    private fun calculateFileSha256(file: File): String? = try {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { stream ->
            val buffer = ByteArray(hashBufferSizeBytes)
            while (true) {
                val read = stream.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        digest.digest().joinToString("") { "%02x".format(it) }
    } catch (_: Exception) {
        null
    }

    private fun hasSplitConfiguration(
        fileName: String,
        packageInfo: android.content.pm.PackageInfo?
    ): Boolean {
        val normalized = fileName.lowercase(Locale.ROOT)
        val nameSignalsSplit =
            normalized.startsWith("split_config.") ||
                normalized.contains("-split_config.") ||
                normalized.contains("_split_config.") ||
                normalized.startsWith("config.")
        val splitNames = packageInfo?.splitNames
        val packageSignalsSplit = splitNames != null && splitNames.isNotEmpty()
        return nameSignalsSplit || packageSignalsSplit
    }

    private fun inferAbi(fileName: String): String? {
        val normalized = fileName.lowercase(Locale.ROOT)
        return when {
            normalized.contains("arm64-v8a") -> "arm64-v8a"
            normalized.contains("armeabi-v7a") -> "armeabi-v7a"
            normalized.contains("x86_64") -> "x86_64"
            normalized.contains("x86") -> "x86"
            normalized.contains("universal") -> "universal"
            else -> null
        }
    }
}
