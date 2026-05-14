import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';

class BundledModelRegistryService {
  const BundledModelRegistryService();

  static const String manifestAssetPath = 'assets/models/manifest.json';

  Future<List<Map<String, dynamic>>> loadCatalog() async {
    try {
      final raw = await rootBundle.loadString(manifestAssetPath);
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        debugPrint(
          '[MODEL_LOAD] Asset manifest did not contain a list; falling back to AppConstants.availableModels.',
        );
        return AppConstants.availableModels;
      }
      return decoded
          .whereType<Map>()
          .map(
            (entry) => entry.map(
              (key, value) => MapEntry(key.toString(), value),
            ),
          )
          .toList(growable: false);
    } catch (error) {
      debugPrint(
        '[MODEL_LOAD] Failed to load $manifestAssetPath, using fallback catalog: $error',
      );
      return AppConstants.availableModels;
    }
  }
}
