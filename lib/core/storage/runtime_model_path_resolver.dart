import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum RuntimeModelStorageLocation {
  publicDownload,
  privateApp,
}

class RuntimeModelResolution {
  const RuntimeModelResolution({
    required this.file,
    required this.publicFile,
    required this.privateFile,
    required this.location,
  });

  final File file;
  final File publicFile;
  final File privateFile;
  final RuntimeModelStorageLocation? location;

  bool get exists => location != null;
}

class RuntimeModelPathResolver {
  const RuntimeModelPathResolver();

  static const String publicModelsDirectoryPath =
      '/storage/emulated/0/Download/AiOrchestrator/models';

  File publicFileByName(String fileName) =>
      File(p.join(publicModelsDirectoryPath, fileName));

  Future<File> privateFileByName(
    String fileName, {
    String? relativeDirectory,
  }) async {
    final privateRoot = await privateModelsDirectory();
    final privateDirPath = (relativeDirectory == null || relativeDirectory.trim().isEmpty)
        ? privateRoot.path
        : p.join(
            privateRoot.parent.path,
            relativeDirectory,
          );
    return File(p.join(privateDirPath, fileName));
  }

  Future<Directory> privateModelsDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory(p.join(appDir.path, 'models'));
  }

  Future<Directory> ensurePublicModelsDirectory() async {
    final dir = Directory(publicModelsDirectoryPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<RuntimeModelResolution> resolveForRead({
    required String fileName,
    String? privateRelativeDirectory,
    String? privateAbsolutePathHint,
  }) async {
    final publicFile = publicFileByName(fileName);
    final privateFile = privateAbsolutePathHint == null ||
            privateAbsolutePathHint.trim().isEmpty
        ? await privateFileByName(
            fileName,
            relativeDirectory: privateRelativeDirectory,
          )
        : File(privateAbsolutePathHint);

    if (Platform.isAndroid && await _safeExistsWithContent(publicFile)) {
      return RuntimeModelResolution(
        file: publicFile,
        publicFile: publicFile,
        privateFile: privateFile,
        location: RuntimeModelStorageLocation.publicDownload,
      );
    }

    if (await _safeExistsWithContent(privateFile)) {
      return RuntimeModelResolution(
        file: privateFile,
        publicFile: publicFile,
        privateFile: privateFile,
        location: RuntimeModelStorageLocation.privateApp,
      );
    }

    return RuntimeModelResolution(
      file: privateFile,
      publicFile: publicFile,
      privateFile: privateFile,
      location: null,
    );
  }

  Future<bool> _safeExistsWithContent(File file) async {
    try {
      if (!await file.exists()) {
        return false;
      }
      return await file.length() > 0;
    } catch (_) {
      return false;
    }
  }
}
