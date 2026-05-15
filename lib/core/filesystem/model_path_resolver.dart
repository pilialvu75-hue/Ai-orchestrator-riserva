import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:ai_orchestrator/core/filesystem/filesystem_paths.dart';

class ModelPathResolver {
  static const List<int> _ggufMagic = [0x47, 0x47, 0x55, 0x46];

  Future<String?> resolveModelPath(
    String modelId, {
    String? userProvidedPath,
  }) async {
    debugPrint('[MODEL_VALIDATION] Resolving model path for id: $modelId');

    if (userProvidedPath != null && userProvidedPath.isNotEmpty) {
      final valid = await hasValidGgufHeader(userProvidedPath);
      if (valid) {
        debugPrint(
          '[MODEL_VALIDATION] OK – using user-provided path: $userProvidedPath',
        );
        return userProvidedPath;
      }
      debugPrint(
        '[MODEL_VALIDATION] User-provided path failed GGUF check: $userProvidedPath',
      );
    }

    final modelsDir = await FilesystemPaths.getModelsDirectoryPath();
    final candidatePath = p.join(modelsDir, '$modelId.gguf');

    if (await isModelPresent(candidatePath)) {
      final valid = await hasValidGgufHeader(candidatePath);
      if (valid) {
        debugPrint(
          '[MODEL_VALIDATION] OK – found model in models directory: $candidatePath',
        );
        return candidatePath;
      }
      debugPrint(
        '[MODEL_VALIDATION] Model in models directory failed GGUF check: $candidatePath',
      );
    }

    debugPrint('[MODEL_VALIDATION] FAIL – could not resolve model: $modelId');
    return null;
  }

  Future<bool> isModelPresent(String modelPath) async {
    return File(modelPath).existsSync();
  }

  Future<bool> hasValidGgufHeader(String modelPath) async {
    debugPrint('[MODEL_VALIDATION] Checking GGUF header: $modelPath');

    final file = File(modelPath);
    if (!file.existsSync()) return false;

    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final header = await raf.read(4);
      if (header.length < 4) return false;

      for (int i = 0; i < 4; i++) {
        if (header[i] != _ggufMagic[i]) return false;
      }
      return true;
    } catch (e) {
      debugPrint('[MODEL_VALIDATION] FAIL – cannot read header: $e');
      return false;
    } finally {
      await raf?.close();
    }
  }

  Future<void> ensureModelDirectoryExists() async {
    final modelsDir = await FilesystemPaths.getModelsDirectoryPath();
    final dir = Directory(modelsDir);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
      debugPrint('[MODEL_VALIDATION] Created models directory: $modelsDir');
    }
  }
}
