import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';

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
    final privateDirPath =
        (relativeDirectory == null || relativeDirectory.trim().isEmpty)
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

    // 1. PRIORITÀ ASSOLUTA: Controlla e preferisce la copia privata dell'app
    // Questo evita richieste di permessi di archiviazione su Android 11+ / 13+
    if (await _safeExistsWithContent(privateFile)) {
      return RuntimeModelResolution(
        file: privateFile,
        publicFile: publicFile,
        privateFile: privateFile,
        location: RuntimeModelStorageLocation.privateApp,
      );
    }

    // 2. FALLBACK: Se non esiste nella cartella privata, controlla i Download pubblici (Android)
    if (Platform.isAndroid && await _safeExistsWithContent(publicFile)) {
      return RuntimeModelResolution(
        file: publicFile,
        publicFile: publicFile,
        privateFile: privateFile,
        location: RuntimeModelStorageLocation.publicDownload,
      );
    }

    // 3. DEFAULT: Restituisce il riferimento privato (il file non esiste ancora)
    return RuntimeModelResolution(
      file: privateFile,
      publicFile: publicFile,
      privateFile: privateFile,
      location: null,
    );
  }

  // ===========================================================================
  // PERCORSI MODELLI VOCALI FASE 2 (STT & TTS)
  // ===========================================================================

  Future<String> get sttEncoderPath async =>
      (await resolveForRead(fileName: AppConstants.sttEncoderFile)).file.path;

  Future<String> get sttDecoderPath async =>
      (await resolveForRead(fileName: AppConstants.sttDecoderFile)).file.path;

  Future<String> get sttJoinerPath async =>
      (await resolveForRead(fileName: AppConstants.sttJoinerFile)).file.path;

  Future<String> get sttTokensPath async =>
      (await resolveForRead(fileName: AppConstants.sttTokensFile)).file.path;

  Future<String> get ttsModelPath async =>
      (await resolveForRead(fileName: AppConstants.ttsModelFile)).file.path;

  Future<String> get ttsTokensPath async =>
      (await resolveForRead(fileName: AppConstants.ttsTokensFile)).file.path;

  Future<String> get ttsEspeakDataDirPath async {
    final privateRoot = await privateModelsDirectory();
    final dir = Directory(p.join(privateRoot.path, AppConstants.ttsEspeakDataDir));
    return dir.path;
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
