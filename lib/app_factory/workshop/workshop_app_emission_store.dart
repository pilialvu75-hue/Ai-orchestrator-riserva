import 'dart:convert';

import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_package.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_registry.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_repair.dart';

/// Durable catalogue shared by the production builder and the emitted-app UI.
/// A failed build cannot create an entry. Project recovery remains separate.
final class WorkshopAppEmissionStore {
  WorkshopAppEmissionStore(this.preferences);

  final PreferencesService preferences;
  static const storageKey = 'workshop.app_emissions.v1';
  static Future<void> _tail = Future<void>.value();

  WorkshopAppEmissionRegistry load() {
    final encoded = preferences.getString(storageKey);
    if (encoded == null) return WorkshopAppEmissionRegistry();
    return WorkshopAppEmissionRegistry.fromJson(
      Map<String, dynamic>.from(jsonDecode(encoded) as Map),
    );
  }

  Future<WorkshopAppEmissionPackage?> recordVerifiedBuild({
    required WorkshopBuildResult result,
    required String projectId,
    required String appName,
  }) async {
    if (!const WorkshopBuildRepairPlanner().assess(result).isVerifiedSuccess) {
      return null;
    }
    final package = WorkshopAppEmissionPackage(
      id: 'build:${result.requestId}',
      requestId: result.requestId,
      target: result.target.name,
      artifactPath: result.artifactPath!,
      createdAt: result.finishedAt,
      appName: appName,
      metadata: <String, dynamic>{'projectId': projectId},
    );
    final operation = _tail.then((_) async {
      final registry = load();
      registry.removeById(package.id);
      registry.register(package);
      await preferences.setString(storageKey, jsonEncode(registry.toJson()));
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    await operation;
    return package;
  }
}
