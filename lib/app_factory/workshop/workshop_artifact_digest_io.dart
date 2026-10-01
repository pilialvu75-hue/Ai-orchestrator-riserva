import 'dart:io';

import 'package:crypto/crypto.dart';

abstract final class WorkshopArtifactDigest {
  static Future<String?> sha256File(String? path) async {
    final normalized = path?.trim();
    if (normalized == null || normalized.isEmpty) return null;

    final file = File(normalized);
    if (!await file.exists()) return null;

    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}
