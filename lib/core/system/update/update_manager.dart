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
import 'package:ai_orchestrator/core/system/update/update_state.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';
import 'package:ai_orchestrator/native/platform/android_intent_handler.dart';

class UpdateManager {
  static const String _prefPendingApkPath = 'update_pending_apk_path';
  static const String _prefPendingVersion = 'update_pending_version';
  static const String _prefPendingSavedAt = 'update_pending_saved_at';

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
        _currentVersion = currentVersion,
        _dio = dio ?? Dio(),
        state = ValueNotifier<UpdateState>(
          UpdateState.initial(
            currentVersion: currentVersion,
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
    if (checkOnStartup) {
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
    _logUpdateTag('check_start');
    if (state.value.status == UpdateStatus.downloading) {
      _logUpdate('Skipping check while download is in progress');
      return;
    }
    _logVersion('Current installed version: $_currentVersion');
    state.value = state.value.copyWith(
      status: UpdateStatus.checking,
      clearErrorMessage: true,
    );

    final result = await _updateChecker.checkLatestManifest(
      preferredChannel: state.value.preferredChannel,
    );

    final manifest = result.manifest;
    if (manifest == null) {
      _logUpdateTag('check_fail error=${result.errorMessage}');
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

    _logVersion(
      'Latest remote version=${manifest.version} versionCode=${manifest.versionCode ?? '-'} url=${manifest.apkUrl}',
    );
    _logUpdateTag(
      'check_result remote_version=${manifest.version} url=${manifest.apkUrl}',
    );

    if (!manifest.isCompatibleWith(
      currentVersion: _currentVersion,
      comparator: _comparator,
    )) {
      _logVersion(
        'Current version $_currentVersion is below min_supported ${manifest.minSupported}',
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

    final hasNewer = _comparator.isNewer(
      latest: manifest.version,
      current: _currentVersion,
    );
    _logVersion(
      'Version compare latest=${manifest.version} current=$_currentVersion hasNewer=$hasNewer',
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

    _logUpdateDownload('start url=${manifest.apkUrl}');
    _logApk('Starting APK download from ${manifest.apkUrl}');
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
      final tempDirectory = await getTemporaryDirectory();
      final updatesDirectory = Directory('${tempDirectory.path}/app_updates');
      if (!await updatesDirectory.exists()) {
        await updatesDirectory.create(recursive: true);
      }

      final extension = p.extension(uri.path).isEmpty ? '.apk' : p.extension(uri.path);
      final fileName = 'ai_orchestrator_update_${DateTime.now().millisecondsSinceEpoch}$extension';
      final filePath = '${updatesDirectory.path}/$fileName';
      _logApk('Saving APK to: $filePath');

      await _dio.download(
        manifest.apkUrl,
        filePath,
        options: Options(
          followRedirects: true,
          receiveTimeout: const Duration(minutes: 10),
        ),
        onReceiveProgress: (received, total) {
          final progress = total <= 0 ? 0.0 : (received / total).clamp(0.0, 1.0);
          _logApk('Download progress received=$received total=$total progress=${(progress * 100).toStringAsFixed(1)}%');
          state.value = state.value.copyWith(
            status: UpdateStatus.downloading,
            downloadProgress: progress,
          );
        },
      );

      final apkFile = File(filePath);
      final exists = await apkFile.exists();
      final fileSize = exists ? await apkFile.length() : 0;
      final hasApkExt = p.extension(filePath).toLowerCase() == '.apk';
      _logApk(
        'Download finished. apkPath=$filePath exists=$exists size_bytes=$fileSize has_apk_ext=$hasApkExt',
      );
      if (!exists || fileSize <= 0 || !hasApkExt) {
        _logUpdateDownload(
          'fail_integrity exists=$exists size_bytes=$fileSize has_apk_ext=$hasApkExt',
        );
        state.value = state.value.copyWith(
          status: UpdateStatus.error,
          errorMessage: 'Downloaded APK failed integrity checks.',
          diagnostics: state.value.diagnostics.copyWith(
            apkDownloaded: false,
            apkPath: filePath,
            apkFileExists: exists,
            lastException:
                'APK integrity failed: exists=$exists size=$fileSize ext_ok=$hasApkExt',
          ),
        );
        return false;
      }
      _logUpdateDownload('complete path=$filePath size_bytes=$fileSize');

      state.value = state.value.copyWith(
        status: UpdateStatus.readyToInstall,
        tempApkPath: filePath,
        downloadProgress: 1,
        diagnostics: state.value.diagnostics.copyWith(
          apkDownloaded: true,
          apkPath: filePath,
          apkFileExists: exists,
          clearLastException: true,
        ),
      );
      await _persistPendingInstallerState(
        apkPath: filePath,
        version: manifest.version,
      );
      return true;
    } catch (e, st) {
      _logUpdateDownload('fail error=$e');
      _logApk('Download failed: $e');
      _logApk('Download stack: $st');
      state.value = state.value.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Download failed: $e',
        diagnostics: state.value.diagnostics.copyWith(
          apkDownloaded: false,
          apkFileExists: false,
          lastException: 'Download failed: $e',
        ),
      );
      return false;
    }
  }

  Future<bool> prepareInstallIntent() async {
    _logUpdateInstallStart();
    _logUpdateApply('begin');
    await _syncAndroidInstallDiagnostics();
    final apkPath = state.value.tempApkPath;
    if (apkPath == null || apkPath.isEmpty) {
      _logUpdateApply('fail reason=missing_apk_path');
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

    final apkFile = File(apkPath);
    final exists = await apkFile.exists();
    _logInstall('Preparing installer launch. apkPath=$apkPath exists=$exists');
    if (!exists) {
      _logUpdateApply('fail reason=apk_missing');
      _logUpdateInstallFail('Downloaded APK file is missing');
      state.value = state.value.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Downloaded APK file is missing',
        diagnostics: state.value.diagnostics.copyWith(
          apkDownloaded: true,
          apkPath: apkPath,
          apkFileExists: false,
          installerLaunchSuccess: false,
          lastException: 'Downloaded APK file is missing',
        ),
      );
      return false;
    }

    final result = await _intentHandler.openApkInstaller(apkPath);
    if (result.isLeft()) {
      final failure = result.swap().getOrElse(() => throw StateError('Unexpected empty failure'));
      _logUpdateApply('fail reason=${failure.message}');
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
      _logUpdateApply('fail reason=installer_launch_returned_false');
      _logUpdateInstallFail('installer_launch_returned_false');
      state.value = state.value.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Installer launch failed.',
      );
      return false;
    }
    _logUpdateInstallSuccess();
    _logUpdateApply('success installer_launched=true');
    state.value = state.value.copyWith(
      status: UpdateStatus.idle,
      clearTempApkPath: true,
      downloadProgress: 0,
      diagnostics: state.value.diagnostics.copyWith(
        installerLaunchSuccess: success,
        apkDownloaded: true,
        apkPath: apkPath,
        apkFileExists: true,
        clearLastException: success,
      ),
    );
    await _cleanupInstallerArtifacts(apkPath);
    await _clearPendingInstallerState();
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
    final apkFile = File(pendingPath);
    final exists = await apkFile.exists();
    if (!exists) {
      _logUpdateResume('stale_pending_path_missing path=$pendingPath');
      await _clearPendingInstallerState();
      state.value = state.value.copyWith(
        status: UpdateStatus.idle,
        clearTempApkPath: true,
      );
      return;
    }
    final hasValidApkExtension = p.extension(pendingPath).toLowerCase() == '.apk';
    final fileSize = await apkFile.length();
    if (!hasValidApkExtension || fileSize <= 0) {
      _logUpdateResume(
        'stale_pending_path_invalid path=$pendingPath size_bytes=$fileSize has_apk_ext=$hasValidApkExtension',
      );
      try {
        await apkFile.delete();
        _logUpdateCleanup('stale_apk_deleted path=$pendingPath');
      } catch (error) {
        _logUpdateCleanup('stale_apk_delete_failed path=$pendingPath error=$error');
      }
      await _clearPendingInstallerState();
      state.value = state.value.copyWith(
        status: UpdateStatus.idle,
        clearTempApkPath: true,
      );
      return;
    }
    final version = _preferences.getString(_prefPendingVersion);
    _logUpdateResume(
      'ready_to_resume path=$pendingPath version=${version ?? 'unknown'}',
    );
    state.value = state.value.copyWith(
      status: UpdateStatus.readyToInstall,
      tempApkPath: pendingPath,
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
    _logUpdateResume('persisted_pending_installer path=$apkPath version=$version');
  }

  Future<void> _clearPendingInstallerState() async {
    await _preferences.remove(_prefPendingApkPath);
    await _preferences.remove(_prefPendingVersion);
    await _preferences.remove(_prefPendingSavedAt);
    _logUpdateCleanup('pending_state_cleared');
  }

  Future<void> _cleanupInstallerArtifacts(String apkPath) async {
    final file = File(apkPath);
    if (!await file.exists()) {
      _logUpdateCleanup('apk_missing path=$apkPath');
      return;
    }
    try {
      await file.delete();
      _logUpdateCleanup('apk_deleted path=$apkPath');
    } catch (error) {
      _logUpdateCleanup('apk_delete_failed path=$apkPath error=$error');
    }
  }

  void _logUpdate(String message) => debugPrint('[UPDATE] $message');
  void _logApk(String message) => debugPrint('[APK] $message');
  void _logVersion(String message) => debugPrint('[VERSION] $message');
  void _logInstall(String message) => debugPrint('[INSTALL] $message');
  void _logUpdateTag(String message) => debugPrint('[UPDATE_CHECK] $message');
  void _logUpdateDownload(String message) => debugPrint('[UPDATE_DOWNLOAD] $message');
  void _logUpdateInstallStart() => debugPrint('[UPDATE_INSTALL_START] begin');
  void _logUpdateInstallFail(String reason) =>
      debugPrint('[UPDATE_INSTALL_FAIL] reason=$reason');
  void _logUpdateInstallSuccess() => debugPrint('[UPDATE_INSTALL_SUCCESS] launched=true');
  void _logUpdateResume(String message) => debugPrint('[UPDATE_RESUME] $message');
  void _logUpdateApply(String message) => debugPrint('[UPDATE_APPLY] $message');
  void _logUpdateCleanup(String message) => debugPrint('[UPDATE_CLEANUP] $message');

  void dispose() {
    stopBackgroundChecks();
    state.dispose();
  }
}
