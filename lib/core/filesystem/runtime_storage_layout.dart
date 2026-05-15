import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/filesystem/filesystem_paths.dart';

class RuntimeStorageLayout {
  Future<void> initialize() async {
    final dirs = await Future.wait([
      modelsDirectory,
      cacheDirectory,
      runtimeDirectory,
      downloadsDirectory,
      tempDirectory,
    ]);

    for (final path in dirs) {
      final dir = Directory(path);
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
    }

    debugPrint('[RUNTIME_STATE] OK – runtime storage layout initialized');
  }

  Future<String> get modelsDirectory => FilesystemPaths.getModelsDirectoryPath();

  Future<String> get cacheDirectory => FilesystemPaths.getCachePath();

  Future<String> get runtimeDirectory => FilesystemPaths.getRuntimeStoragePath();

  Future<String> get downloadsDirectory => FilesystemPaths.getDownloadsPath();

  Future<String> get tempDirectory async {
    // Uses the OS temp directory; separate from the app cache dir.
    return Directory.systemTemp.path;
  }
}
