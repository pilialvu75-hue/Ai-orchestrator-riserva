import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/system/update/release_channel.dart';
import 'package:ai_orchestrator/core/system/update/update_checker.dart';
import 'package:ai_orchestrator/core/system/update/update_manifest.dart';
import 'package:ai_orchestrator/core/system/update/update_state.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';
import 'package:ai_orchestrator/native/platform/android_intent_handler.dart';

class _ApkVerificationResult {
  const _ApkVerificationResult({
    required this.valid,
    required this.exists,
    required this.readable,
    required this.hasApkExtension,
    required this.sizeBytes,
    required this.reason,
  });

  final bool valid;
  final bool exists;
  final bool readable;
  final bool hasApkExtension;
  final int sizeBytes;
  final String reason;
}

class UpdateManager {
  static const String _prefPendingApkPath = 'update_pending_apk_path';
  static const String _prefPendingVersion = 'update_pending_version';
  static const String _prefPendingSavedAt = 'update_pending_saved_at';
  static const String _prefDownloadPartialPath = 'update_download_partial_path';
  static const String _prefDownloadVersion = 'update_download_version';
  static const String _prefDownloadProgress = 'update_download_progress';
  static const String _prefDownloadReceivedBytes =
      'update_download_received_bytes';
  static const String _prefDownloadTotalBytes = 'update_download_total_bytes';
  static const int _minValidApkBytes = 64 * 1024;
  static const Duration _downloadTimeout = Duration(minutes: 10);
  static const String _updatesDirectoryName = 'app_updates';
  static const String _defaultApkFileName = 'ai_orchestrator_update.apk';

  UpdateManager({
    required UpdateChecker updateChecker,
    required VersionComparator comparator,
    required SharedPreferences preferences,
    required AndroidIntentHandler intentHandler,
    required String currentVersion,
    Dio? dio,
  })  : _updateChecker = updateChecker,
        _comparator = comparator,
        _preferences = preferences,
        _intentHandler = intentHandler,
        _currentVersion = comparator.normalize(currentVersion) ?? currentVersion,
        _dio = dio ?? Dio(),
        state = ValueNotifier<UpdateState>(
          UpdateState.initial(
            currentVersion: comparator.normalize(currentVersion) ?? currentVersion,
            preferredChannel: ReleaseChannel.fromString(
              preferences.getString(AppConstants.prefReleaseChannel),
            ),
          ),
        );

  final UpdateChecker _updateChecker;
  final VersionComparator _comparator;
  final SharedPreferences _preferences;
  final AndroidIntentHandler _intentHandler;
  final String _currentVersion;
  final Dio _dio;

  final ValueNotifier<UpdateState> state;

  Timer? _periodicTimer;

  Future<void> startBackgroundChecks({
    bool checkOnStartup = true,
    Duration interval = const Duration(hours: 12),
  }) async {
    await _resumePendingInstallerState();
    if (checkOnStartup && state.value.status != UpdateStatus.readyToInstall) {
      unawaited(checkForUpdates());
    }

    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(interval, (_) {
      unawaited(checkForUpdates());
    });
  }

  void stopBackgroundChecks() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  Future<void> setPreferredChannel(ReleaseChannel channel) async {
    await _preferences.setString(
      AppConstants.prefReleaseChannel,
      channel.storageValue,
    );
    state.value = state.value.copyWith(preferredChannel: channel);
    unawaited(checkForUpdates());
  }

  Future<void> checkForUpdates() async {
    _logUpdateCheck('check_start');
    if (state.value.status == UpdateStatus.downloading) {
      _logUpdate('Skipping check while download is in progress');
      return;
    }
    if (state.value.status == UpdateStatus.readyToInstall &&
        state.value.tempApkPath != null &&
        state.value.tempApkPath!.isNotEmpty) {
      _logUpdateInstallResume(
        'skip_check_ready_to_install path=${state.value.tempApkPath}',
      );
      return;
    }

    _logVersionLocal('version=$_currentVersion');
    state.value = state.value.copyWith(
      status: UpdateStatus.checking,
      clearErrorMessage: true,
    );

    final result = await _updateChecker.checkLatestManifest(
      preferredChannel: state.value.preferredChannel,
    );

    final manifest = result.manifest;
    if (manifest == null) {
      _logUpdateCheck('check_fail error=${result.errorMessage}');
      _logUpdate('Update check failed: ${result.errorMessage}');
      state.value = state.value.copyWith(
        status: UpdateStatus.error,
        errorMessage: result.errorMessage ?? 'Update check failed',
        lastCheckedAt: DateTime.now(),
        diagnostics: state.value.diagnostics.copyWith(
          lastException: result.errorMessage ?? 'Update check failed',
        ),
      );
      return;
    }

    _logVersionRemote(
      'version=${manifest.version} versionCode=${manifest.versionCode ?? '-'} url=${manifest.apkUrl}',
    );
    _logUpdateCheck(
      'check_result remote_version=${manifest.version} url=${manifest.apkUrl}',
    );

    if (!manifest.isCompatibleWith(
      currentVersion: _currentVersion,
      comparator: _comparator,
    )) {
      _logVersionCompare(
        'local=$_currentVersion remote=${manifest.version} compatible=false',
      );
      state.value = state.value.copyWith(
        status: UpdateStatus.upToDate,
        latestManifest: manifest,
        lastCheckedAt: DateTime.now(),
        usedCachedManifest: result.usedCache,
        diagnostics: state.value.diagnostics.copyWith(
          remoteVersion: manifest.version,
          remoteVersionCode: manifest.versionCode,
          updateUrl: manifest.apkUrl,
          clearLastException: true,
        ),
      );
      return;
    }

    final compareResult = _comparator.compare(manifest.version, _currentVersion);
    final hasNewer = compareResult > 0;
    _logVersionCompare(
      'local=$_currentVersion remote=${manifest.version} compare=$compareResult has_newer=$hasNewer',
    );

    state.value = state.value.copyWith(
      status: hasNewer ? UpdateStatus.updateAvailable : UpdateStatus.upToDate,
      latestManifest: manifest,
      lastCheckedAt: DateTime.now(),
      usedCachedManifest: result.usedCache,
      clearErrorMessage: true,
      clearTempApkPath: true,
      downloadProgress: 0,
      diagnostics: state.value.diagnostics.copyWith(
        remoteVersion: manifest.version,
        remoteVersionCode: manifest.versionCode,
        updateUrl: manifest.apkUrl,
        apkDownloaded: false,
        clearApkPath: true,
        apkFileExists: false,
        clearInstallerLaunchSuccess: true,
        clearLastException: true,
      ),
    );
  }

  Future<bool> downloadLatestApk() async {
    final manifest = state.value.latestManifest;
    if (manifest == null) {
      _logApk('Download requested without latest manifest');
      return false;
    }

    final uri = Uri.tryParse(manifest.apkUrl);
    if (uri == null ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty) {
      _logApk('Rejected invalid APK URL: ${manifest.apkUrl}');
      state.value = state.value.copyWith(
        status: UpdateStatus.error,
        errorMessage:
            'Previously validated APK URL is now invalid: ${manifest.apkUrl}',
        diagnostics: state.value.diagnostics.copyWith(
          lastException: 'Invalid APK URL: ${manifest.apkUrl}',
        ),
      );
      return false;
    }

    await _cleanupObsoleteDownloadedApks(activeVersion: manifest.version);
    final updatesDirectory = await _ensureVersionScopedUpdateDirectory(
      manifest.version,
    );
    final fileName = _resolveApkFileName(manifest, uri);
    final finalPath = p.join(updatesDirectory.path, fileName);
    final partialPath = '$finalPath.part';
    var activePath = partialPath;

    state.value = state.value.copyWith(
      status: UpdateStatus.downloading,
      downloadProgress: 0,
      clearErrorMessage: true,
      clearTempApkPath: true,
      diagnostics: state.value.diagnostics.copyWith(
        updateUrl: manifest.apkUrl,
        apkDownloaded: false,
        clearApkPath: true,
        apkFileExists: false,
        clearInstallerLaunchSuccess: true,
        clearLastException: true,
      ),
    );

    try {
      final finalFile = File(finalPath);
      if (await finalFile.exists()) {
        final verified = await _verifyApkFile(
          finalPath,
          expectedSizeBytes: manifest.apkSizeBytes,
        );
        if (verified.valid) {
          _logUpdateDownloadComplete(
            'reuse_existing path=$finalPath size_bytes=${verified.sizeBytes}',
          );
          await _clearDownloadState();
          await _persistPendingInstallerState(
            apkPath: finalPath,
            version: manifest.version,
          );
          state.value = state.value.copyWith(
            status: UpdateStatus.readyToInstall,
            tempApkPath: finalPath,
            downloadProgress: 1,
            diagnostics: state.value.diagnostics.copyWith(
              apkDownloaded: true,
              apkPath: finalPath,
              apkFileExists: true,
              clearLastException: true,
            ),
          );
          return true;
        }
        await _cleanupInstallerArtifacts(finalPath);
      }

      final partialFile = File(partialPath);
      final existingPartialBytes =
          await partialFile.exists() ? await partialFile.length() : 0;
      await _persistDownloadState(
        partialPath: partialPath,
        version: manifest.version,
        progress: 0,
        receivedBytes: existingPartialBytes,
        totalBytes: manifest.apkSizeBytes,
      );
      _logUpdateDownloadStart(
        'url=${manifest.apkUrl} path=$partialPath resume_bytes=$existingPartialBytes',
      );
      await _downloadApkToPartialFile(
        manifest: manifest,
        partialFile: partialFile,
        existingPartialBytes: existingPartialBytes,
      );

      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await partialFile.rename(finalPath);
      activePath = finalPath;

      final verification = await _verifyApkFile(
        finalPath,
        expectedSizeBytes: manifest.apkSizeBytes,
      );
      if (!verification.valid) {
        await _cleanupInstallerArtifacts(finalPath);
        await _clearDownloadState();
        _logUpdateDownloadFail(
          'reason=${verification.reason} path=$finalPath size_bytes=${verification.sizeBytes}',
        );
        state.value = state.value.copyWith(
          status: UpdateStatus.error,
          errorMessage: 'Downloaded APK failed verification: ${verification.reason}',
          diagnostics: state.value.diagnostics.copyWith(
            apkDownloaded: false,
            apkPath: finalPath,
            apkFileExists: verification.exists,
            lastException: 'APK verification failed: ${verification.reason}',
          ),
        );
        return false;
      }

      await _clearDownloadState();
      await _persistPendingInstallerState(
        apkPath: finalPath,
        version: manifest.version,
      );
      _logUpdateDownloadComplete(
        'path=$finalPath size_bytes=${verification.sizeBytes}',
      );
      state.value = state.value.copyWith(
        status: UpdateStatus.readyToInstall,
        tempApkPath: finalPath,
        downloadProgress: 1,
        diagnostics: state.value.diagnostics.copyWith(
          apkDownloaded: true,
          apkPath: finalPath,
          apkFileExists: true,
          clearLastException: true,
        ),
      );
      return true;
    } catch (error, stackTrace) {
      _logUpdateDownloadFail('error=$error path=$activePath');
      _logApk('Download failed: $error');
      _logApk('Download stack: $stackTrace');
      state.value = state.value.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Download failed: $error',
        diagnostics: state.value.diagnostics.copyWith(
          apkDownloaded: false,
          apkPath: activePath,
          apkFileExists: await File(activePath).exists(),
          lastException: 'Download failed: $error',
        ),
      );
      return false;
    }
  }

  Future<bool> prepareInstallIntent() async {
    _logUpdateInstallStart();
    await _syncAndroidInstallDiagnostics();
    final apkPath = state.value.tempApkPath;
    if (apkPath == null || apkPath.isEmpty) {
      _logUpdateInstallFail('No downloaded APK available');
      _logInstall('Install requested without downloaded APK');
      state.value = state.value.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'No downloaded APK available',
        diagnostics: state.value.diagnostics.copyWith(
          lastException: 'No downloaded APK available',
          installerLaunchSuccess: false,
        ),
      );
      return false;
    }

    final verification = await _verifyApkFile(
      apkPath,
      expectedSizeBytes: state.value.latestManifest?.apkSizeBytes,
    );
    if (!verification.valid) {
      _logUpdateInstallFail(verification.reason);
      await _cleanupInstallerArtifacts(apkPath);
      await _clearPendingInstallerState();
      state.value = state.value.copyWith(
        status: UpdateStatus.error,
        clearTempApkPath: true,
        errorMessage: 'Downloaded APK is no longer valid: ${verification.reason}',
        diagnostics: state.value.diagnostics.copyWith(
          apkDownloaded: false,
          apkPath: apkPath,
          apkFileExists: verification.exists,
          installerLaunchSuccess: false,
          lastException: 'APK invalid before install: ${verification.reason}',
        ),
      );
      return false;
    }

    final result = await _intentHandler.openApkInstaller(apkPath);
    if (result.isLeft()) {
      final failure = result.swap().getOrElse(
            () => throw StateError('Unexpected empty failure'),
          );
      _logUpdateInstallFail(failure.message);
      _logInstall('Installer launch failed: ${failure.message}');
      state.value = state.value.copyWith(
        status: UpdateStatus.error,
        errorMessage: failure.message,
        diagnostics: state.value.diagnostics.copyWith(
          installerLaunchSuccess: false,
          apkPath: apkPath,
          apkFileExists: true,
          lastException: failure.message,
        ),
      );
      return false;
    }

    final success = result.getOrElse(() => false);
    _logInstall('Installer launch result: success=$success');
    await _syncAndroidInstallDiagnostics();
    if (!success) {
      _logUpdateInstallFail('installer_launch_returned_false');
      state.value = state.value.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Installer launch failed.',
      );
      return false;
    }

    final persistedVersion = state.value.latestManifest?.version ??
        _preferences.getString(_prefPendingVersion) ??
        _currentVersion;
    await _persistPendingInstallerState(
      apkPath: apkPath,
      version: persistedVersion,
    );
    _logUpdateInstallResume(
      'installer_ready path=$apkPath version=$persistedVersion',
    );
    _logUpdateInstallSuccess();
    state.value = state.value.copyWith(
      status: UpdateStatus.readyToInstall,
      tempApkPath: apkPath,
      downloadProgress: 1,
      diagnostics: state.value.diagnostics.copyWith(
        installerLaunchSuccess: success,
        apkDownloaded: true,
        apkPath: apkPath,
        apkFileExists: true,
        clearLastException: true,
      ),
    );
    return success;
  }

  String get currentVersion => _currentVersion;

  Future<bool> openUnknownAppsSettings() async {
    _logInstall('Opening unknown apps permission settings');
    final result = await _intentHandler.openUnknownAppsSettings();
    return result.fold(
      (failure) {
        state.value = state.value.copyWith(
          diagnostics: state.value.diagnostics.copyWith(
            lastException: failure.message,
          ),
        );
        return false;
      },
      (success) => success,
    );
  }

  Future<void> refreshDiagnostics() => _syncAndroidInstallDiagnostics();

  Future<void> _syncAndroidInstallDiagnostics() async {
    final result = await _intentHandler.getInstallDiagnostics();
    result.fold(
      (failure) {
        _logInstall('Diagnostics fetch failed: ${failure.message}');
        state.value = state.value.copyWith(
          diagnostics: state.value.diagnostics.copyWith(
            lastException: state.value.diagnostics.lastException ?? failure.message,
          ),
        );
      },
      (map) {
        _logInstall('Diagnostics payload: $map');
        final sdkInt = map['sdkInt'] is int ? map['sdkInt'] as int : null;
        final canInstall = map['canRequestPackageInstalls'] is bool
            ? map['canRequestPackageInstalls'] as bool
            : null;
        final launchSuccess = map['lastInstallerLaunchSuccess'] is bool
            ? map['lastInstallerLaunchSuccess'] as bool
            : null;
        final lastException = map['lastInstallerException'] is String
            ? map['lastInstallerException'] as String
            : null;
        final resultCode = map['lastInstallerResultCode'] is int
            ? map['lastInstallerResultCode'] as int
            : null;
        state.value = state.value.copyWith(
          diagnostics: state.value.diagnostics.copyWith(
            androidSdkInt: sdkInt,
            canRequestPackageInstalls: canInstall,
            installerLaunchSuccess: launchSuccess,
            lastException: lastException,
            lastInstallerResultCode: resultCode,
            clearAndroidSdkInt: sdkInt == null,
            clearCanRequestPackageInstalls: canInstall == null,
            clearInstallerLaunchSuccess: launchSuccess == null,
            clearLastException: lastException == null,
            clearLastInstallerResultCode: resultCode == null,
          ),
        );
      },
    );
  }

  Future<void> _resumePendingInstallerState() async {
    final pendingPath = _preferences.getString(_prefPendingApkPath);
    if (pendingPath == null || pendingPath.trim().isEmpty) {
      return;
    }

    final pendingVersion = _preferences.getString(_prefPendingVersion);
    if (pendingVersion != null &&
        _comparator.compare(_currentVersion, pendingVersion) >= 0) {
      _logUpdateInstallCleanup(
        'installed_version_reached current=$_currentVersion pending=$pendingVersion',
      );
      await _cleanupInstallerArtifacts(pendingPath);
      await _clearPendingInstallerState();
      state.value = state.value.copyWith(
        status: UpdateStatus.idle,
        clearTempApkPath: true,
      );
      return;
    }

    final verification = await _verifyApkFile(pendingPath);
    if (!verification.valid) {
      _logUpdateInstallCleanup(
        'stale_pending_path_invalid path=$pendingPath reason=${verification.reason}',
      );
      await _cleanupInstallerArtifacts(pendingPath);
      await _clearPendingInstallerState();
      state.value = state.value.copyWith(
        status: UpdateStatus.idle,
        clearTempApkPath: true,
      );
      return;
    }

    _logUpdateInstallResume(
      'ready_to_resume path=$pendingPath version=${pendingVersion ?? 'unknown'}',
    );
    state.value = state.value.copyWith(
      status: UpdateStatus.readyToInstall,
      tempApkPath: pendingPath,
      downloadProgress: 1,
      diagnostics: state.value.diagnostics.copyWith(
        apkDownloaded: true,
        apkPath: pendingPath,
        apkFileExists: true,
      ),
    );
  }

  Future<void> _persistPendingInstallerState({
    required String apkPath,
    required String version,
  }) async {
    await _preferences.setString(_prefPendingApkPath, apkPath);
    await _preferences.setString(_prefPendingVersion, version);
    await _preferences.setInt(
      _prefPendingSavedAt,
      DateTime.now().millisecondsSinceEpoch,
    );
    _logUpdateInstallResume(
      'persisted_pending_installer path=$apkPath version=$version',
    );
  }

  Future<void> _clearPendingInstallerState() async {
    await _preferences.remove(_prefPendingApkPath);
    await _preferences.remove(_prefPendingVersion);
    await _preferences.remove(_prefPendingSavedAt);
    _logUpdateInstallCleanup('pending_state_cleared');
  }

  Future<void> _persistDownloadState({
    required String partialPath,
    required String version,
    required double progress,
    required int receivedBytes,
    int? totalBytes,
  }) async {
    await _preferences.setString(_prefDownloadPartialPath, partialPath);
    await _preferences.setString(_prefDownloadVersion, version);
    await _preferences.setDouble(_prefDownloadProgress, progress);
    await _preferences.setInt(_prefDownloadReceivedBytes, receivedBytes);
    if (totalBytes != null) {
      await _preferences.setInt(_prefDownloadTotalBytes, totalBytes);
    } else {
      await _preferences.remove(_prefDownloadTotalBytes);
    }
  }

  Future<void> _clearDownloadState() async {
    await _preferences.remove(_prefDownloadPartialPath);
    await _preferences.remove(_prefDownloadVersion);
    await _preferences.remove(_prefDownloadProgress);
    await _preferences.remove(_prefDownloadReceivedBytes);
    await _preferences.remove(_prefDownloadTotalBytes);
  }

  Future<Directory> _ensureVersionScopedUpdateDirectory(String version) async {
    final tempDirectory = await getTemporaryDirectory();
    final updateDirectory = Directory(
      p.join(
        tempDirectory.path,
        _updatesDirectoryName,
        _sanitizeVersionForPath(version),
      ),
    );
    if (!await updateDirectory.exists()) {
      await updateDirectory.create(recursive: true);
    }
    return updateDirectory;
  }

  Future<void> _cleanupObsoleteDownloadedApks({
    required String activeVersion,
  }) async {
    final tempDirectory = await getTemporaryDirectory();
    final updatesRoot = Directory(
      p.join(tempDirectory.path, _updatesDirectoryName),
    );
    if (!await updatesRoot.exists()) {
      return;
    }

    final activeKey = _sanitizeVersionForPath(activeVersion);
    await for (final entity in updatesRoot.list()) {
      if (entity is! Directory) {
        continue;
      }
      if (p.basename(entity.path) == activeKey) {
        continue;
      }
      try {
        await entity.delete(recursive: true);
        _logUpdateInstallCleanup('deleted_stale_directory path=${entity.path}');
      } catch (error) {
        _logUpdateInstallCleanup(
          'delete_stale_directory_failed path=${entity.path} error=$error',
        );
      }
    }

    final persistedDownloadVersion = _preferences.getString(_prefDownloadVersion);
    if (persistedDownloadVersion != null && persistedDownloadVersion != activeVersion) {
      final stalePartialPath = _preferences.getString(_prefDownloadPartialPath);
      if (stalePartialPath != null && stalePartialPath.isNotEmpty) {
        await _cleanupInstallerArtifacts(stalePartialPath);
      }
      await _clearDownloadState();
    }
  }

  Future<void> _downloadApkToPartialFile({
    required UpdateManifest manifest,
    required File partialFile,
    required int existingPartialBytes,
  }) async {
    final headers = <String, dynamic>{};
    if (existingPartialBytes > 0) {
      headers[HttpHeaders.rangeHeader] = 'bytes=$existingPartialBytes-';
    }

    final response = await _dio.get<ResponseBody>(
      manifest.apkUrl,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        receiveTimeout: _downloadTimeout,
        headers: headers,
        validateStatus: (status) =>
            status != null &&
            (status == HttpStatus.ok || status == HttpStatus.partialContent),
      ),
    );

    final supportsResume =
        existingPartialBytes > 0 && response.statusCode == HttpStatus.partialContent;
    final sink = partialFile.openWrite(
      mode: supportsResume ? FileMode.append : FileMode.write,
    );
    final reportedLength =
        int.tryParse(response.headers.value(Headers.contentLengthHeader) ?? '');
    final totalBytes = supportsResume
        ? existingPartialBytes + (reportedLength ?? 0)
        : (reportedLength ?? manifest.apkSizeBytes ?? 0);

    var receivedBytes = supportsResume ? existingPartialBytes : 0;
    var lastPersistedProgress = -1.0;
    try {
      await for (final chunk in response.data!.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        final progress = totalBytes > 0
            ? (receivedBytes / totalBytes).clamp(0.0, 1.0)
            : 0.0;
        if (progress == 0 ||
            (progress - lastPersistedProgress).abs() >= 0.01 ||
            progress >= 1) {
          lastPersistedProgress = progress;
          _logUpdateDownloadProgress(
            'received=$receivedBytes total=${totalBytes > 0 ? totalBytes : -1} progress=${(progress * 100).toStringAsFixed(1)}%',
          );
          state.value = state.value.copyWith(
            status: UpdateStatus.downloading,
            downloadProgress: progress,
          );
          await _persistDownloadState(
            partialPath: partialFile.path,
            version: manifest.version,
            progress: progress,
            receivedBytes: receivedBytes,
            totalBytes: totalBytes > 0 ? totalBytes : manifest.apkSizeBytes,
          );
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  Future<_ApkVerificationResult> _verifyApkFile(
    String apkPath, {
    int? expectedSizeBytes,
  }) async {
    final apkFile = File(apkPath);
    final exists = await apkFile.exists();
    final readable = exists && await apkFile.stat().then((_) => true).catchError((_) => false);
    final sizeBytes = exists ? await apkFile.length() : 0;
    final hasApkExtension = p.extension(apkPath).toLowerCase() == '.apk';
    final minimumRequiredBytes = expectedSizeBytes != null &&
            expectedSizeBytes > _minValidApkBytes
        ? expectedSizeBytes
        : _minValidApkBytes;

    var nativeValid = true;
    var reason = 'ok';
    final nativeResult = await _intentHandler.verifyApk(apkPath);
    nativeResult.fold(
      (failure) {
        if (!failure.message.toLowerCase().contains('not available on this platform')) {
          nativeValid = false;
          reason = failure.message;
        }
      },
      (payload) {
        nativeValid = payload['valid'] == true;
        reason = (payload['reason'] as String?) ?? (nativeValid ? 'ok' : 'unknown');
      },
    );

    if (!exists) {
      reason = 'missing';
    } else if (!readable) {
      reason = 'not_readable';
    } else if (!hasApkExtension) {
      reason = 'invalid_extension';
    } else if (sizeBytes < minimumRequiredBytes) {
      reason = 'below_minimum_size';
    } else if (!nativeValid) {
      reason = reason == 'ok' ? 'package_parse_failed' : reason;
    }

    final valid = exists &&
        readable &&
        hasApkExtension &&
        sizeBytes >= minimumRequiredBytes &&
        nativeValid;
    _logUpdateApkVerify(
      'path=$apkPath valid=$valid exists=$exists readable=$readable size_bytes=$sizeBytes reason=$reason',
    );
    return _ApkVerificationResult(
      valid: valid,
      exists: exists,
      readable: readable,
      hasApkExtension: hasApkExtension,
      sizeBytes: sizeBytes,
      reason: reason,
    );
  }

  String _resolveApkFileName(UpdateManifest manifest, Uri uri) {
    final manifestName = manifest.apkFileName?.trim();
    if (manifestName != null &&
        manifestName.isNotEmpty &&
        !manifestName.contains('/') &&
        manifestName.toLowerCase().endsWith('.apk')) {
      return manifestName;
    }

    if (uri.pathSegments.isNotEmpty) {
      final uriName = uri.pathSegments.last.trim();
      if (uriName.isNotEmpty &&
          !uriName.contains('/') &&
          uriName.toLowerCase().endsWith('.apk')) {
        return uriName;
      }
    }

    return _defaultApkFileName;
  }

  String _sanitizeVersionForPath(String version) {
    return version.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '_');
  }

  Future<void> _cleanupInstallerArtifacts(String apkPath) async {
    final file = File(apkPath);
    if (!await file.exists()) {
      _logUpdateInstallCleanup('apk_missing path=$apkPath');
      return;
    }
    try {
      await file.delete();
      _logUpdateInstallCleanup('apk_deleted path=$apkPath');
    } catch (error) {
      _logUpdateInstallCleanup('apk_delete_failed path=$apkPath error=$error');
    }
  }

  void _logUpdate(String message) => debugPrint('[UPDATE] $message');
  void _logApk(String message) => debugPrint('[APK] $message');
  void _logInstall(String message) => debugPrint('[INSTALL] $message');
  void _logUpdateCheck(String message) => debugPrint('[UPDATE_CHECK] $message');
  void _logVersionLocal(String message) =>
      debugPrint('[UPDATE_VERSION_LOCAL] $message');
  void _logVersionRemote(String message) =>
      debugPrint('[UPDATE_VERSION_REMOTE] $message');
  void _logVersionCompare(String message) =>
      debugPrint('[UPDATE_VERSION_COMPARE] $message');
  void _logUpdateDownloadStart(String message) =>
      debugPrint('[UPDATE_DOWNLOAD_START] $message');
  void _logUpdateDownloadProgress(String message) =>
      debugPrint('[UPDATE_DOWNLOAD_PROGRESS] $message');
  void _logUpdateDownloadComplete(String message) =>
      debugPrint('[UPDATE_DOWNLOAD_COMPLETE] $message');
  void _logUpdateDownloadFail(String message) =>
      debugPrint('[UPDATE_DOWNLOAD_FAIL] $message');
  void _logUpdateApkVerify(String message) =>
      debugPrint('[UPDATE_APK_VERIFY] $message');
  void _logUpdateInstallStart() => debugPrint('[UPDATE_INSTALL_START] begin');
  void _logUpdateInstallFail(String reason) =>
      debugPrint('[UPDATE_INSTALL_FAIL] reason=$reason');
  void _logUpdateInstallResume(String message) =>
      debugPrint('[UPDATE_INSTALL_RESUME] $message');
  void _logUpdateInstallSuccess() =>
      debugPrint('[UPDATE_INSTALL_SUCCESS] launched=true');
  void _logUpdateInstallCleanup(String message) =>
      debugPrint('[UPDATE_INSTALL_CLEANUP] $message');

  void dispose() {
    stopBackgroundChecks();
    state.dispose();
  }
}
