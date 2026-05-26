import 'dart:io';

import 'package:dio/dio.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';

class VoiceModelDownloader {
  VoiceModelDownloader({
    Dio? dio,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(hours: 1),
                sendTimeout: const Duration(seconds: 30),
              ),
            );

  static const String sharedModelsFolder =
      '/storage/emulated/0/Download/AiOrchestrator/models';

  final Dio _dio;

  Future<bool> checkAndRequestPermissions() async {
    if (!Platform.isAndroid) {
      return true;
    }

    if (await Permission.manageExternalStorage.isGranted) {
      return true;
    }
    if (await Permission.storage.isGranted) {
      return true;
    }

    final manageStorageStatus = await Permission.manageExternalStorage.request();
    if (manageStorageStatus.isGranted) {
      return true;
    }

    final storageStatus = await Permission.storage.request();
    if (storageStatus.isGranted) {
      return true;
    }

    final mediaStatuses = await <Permission>[
      Permission.audio,
      Permission.photos,
      Permission.videos,
    ].request();
    return mediaStatuses.values
        .every((status) => status.isGranted || status.isLimited);
  }

  Future<void> downloadModels({
    required Function(double) onProgress,
  }) async {
    final targetDir = Directory(sharedModelsFolder);
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    final specs = <_VoiceModelDownloadSpec>[
      _VoiceModelDownloadSpec(
        fileName: AppConstants.sttModelFile,
        url: 'https://pub-models.riconoscimento.ai/whisper-tiny-en.onnx',
        expectedBytes: 78 * 1024 * 1024,
      ),
      _VoiceModelDownloadSpec(
        fileName: AppConstants.sttTokensFile,
        url: 'https://pub-models.riconoscimento.ai/whisper-tiny-en-tokens.txt',
        expectedBytes: 48 * 1024,
      ),
      _VoiceModelDownloadSpec(
        fileName: AppConstants.llmModelFile,
        url: 'https://pub-models.riconoscimento.ai/gemma-2b-it.onnx',
        expectedBytes: 512 * 1024 * 1024,
      ),
      _VoiceModelDownloadSpec(
        fileName: AppConstants.ttsModelFile,
        url: 'https://pub-models.riconoscimento.ai/vits-tts-it.onnx',
        expectedBytes: 126 * 1024 * 1024,
      ),
      _VoiceModelDownloadSpec(
        fileName: AppConstants.ttsLexiconFile,
        url: 'https://pub-models.riconoscimento.ai/vits-tts-lexicon.txt',
        expectedBytes: 2 * 1024 * 1024,
      ),
      _VoiceModelDownloadSpec(
        fileName: AppConstants.ttsTokensFile,
        url: 'https://pub-models.riconoscimento.ai/vits-tts-tokens.txt',
        expectedBytes: 92 * 1024,
      ),
    ];

    final totalExpectedBytes = specs.fold<int>(
      0,
      (sum, spec) => sum + spec.expectedBytes,
    );
    var completedExpectedBytes = 0;
    onProgress(0.0);

    for (final spec in specs) {
      final destinationPath = '${targetDir.path}/${spec.fileName}';
      final destinationFile = File(destinationPath);
      if (destinationFile.existsSync() && destinationFile.lengthSync() > 0) {
        completedExpectedBytes += spec.expectedBytes;
        onProgress(
          (completedExpectedBytes / totalExpectedBytes)
              .clamp(0.0, 1.0)
              .toDouble(),
        );
        continue;
      }

      await _dio.download(
        spec.url,
        destinationPath,
        deleteOnError: true,
        onReceiveProgress: (received, total) {
          final denominator = total > 0 ? total : spec.expectedBytes;
          final fileProgress = (received / denominator).clamp(0.0, 1.0);
          final aggregate = (completedExpectedBytes + fileProgress * spec.expectedBytes) /
              totalExpectedBytes;
          onProgress(aggregate.clamp(0.0, 1.0).toDouble());
        },
      );

      completedExpectedBytes += spec.expectedBytes;
      onProgress(
        (completedExpectedBytes / totalExpectedBytes)
            .clamp(0.0, 1.0)
            .toDouble(),
      );
    }

    onProgress(1.0);
  }
}

class _VoiceModelDownloadSpec {
  const _VoiceModelDownloadSpec({
    required this.fileName,
    required this.url,
    required this.expectedBytes,
  });

  final String fileName;
  final String url;
  final int expectedBytes;
}
