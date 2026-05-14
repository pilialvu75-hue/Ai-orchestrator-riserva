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
      if (decoded is Map<String, dynamic>) {
        return decoded.entries.map((entry) {
          final value = entry.value;
          if (value is! Map) {
            return <String, dynamic>{'id': entry.key};
          }
          return <String, dynamic>{
            'id': entry.key,
            ...value.map(
              (key, value) => MapEntry(key.toString(), value),
            ),
          };
        }).toList(growable: false);
      }
      debugPrint(
        '[MODEL_LOAD] Asset manifest did not contain a keyed object; falling back to AppConstants.availableModels.',
      );
      return AppConstants.availableModels;
    } catch (error) {
      debugPrint(
        '[MODEL_LOAD] Failed to load $manifestAssetPath, using fallback catalog: $error',
      );
      return AppConstants.availableModels;
    }
  }
}
