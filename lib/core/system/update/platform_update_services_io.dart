import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/system/update/update_checker.dart';
import 'package:ai_orchestrator/core/system/update/update_manager.dart';
import 'package:ai_orchestrator/core/system/update/update_manifest.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';
import 'package:ai_orchestrator/core/system/update/windows_update_manager.dart';
import 'package:ai_orchestrator/native/platform/android_intent_handler.dart';

Future<void> configurePlatformUpdateServices(
  GetIt sl, {
  required String currentVersion,
}) async {
  if (!Platform.isWindows) return;

  if (sl.isRegistered<UpdateManager>()) {
    await sl.unregister<UpdateManager>();
  }
  if (sl.isRegistered<UpdateChecker>()) {
    await sl.unregister<UpdateChecker>();
  }

  sl.registerLazySingleton<UpdateChecker>(
    () => UpdateChecker(
      httpClient: sl<http.Client>(),
      preferences: sl<SharedPreferences>(),
      comparator: sl<VersionComparator>(),
      manifestUrl: AppConstants.updateManifestUrl,
      githubOwner: AppConstants.updateGitHubOwner,
      githubRepo: AppConstants.updateGitHubRepo,
      targetPlatform: UpdateTargetPlatform.windows,
    ),
  );

  sl.registerLazySingleton<UpdateManager>(
    () => WindowsUpdateManager(
      updateChecker: sl<UpdateChecker>(),
      comparator: sl<VersionComparator>(),
      preferences: sl<SharedPreferences>(),
      intentHandler: sl<AndroidIntentHandler>(),
      currentVersion: currentVersion,
    ),
  );
}
