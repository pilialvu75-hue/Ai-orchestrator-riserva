import 'dart:io';

import 'package:dio/dio.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/storage/runtime_model_path_resolver.dart';

class VoiceAssetException implements Exception {
  const VoiceAssetException(this.message);

  final String message;

  @override
  String toString() => message;
}

class VoiceModelDownloader with RuntimeEventEmitter {
  VoiceModelDownloader({
    Dio? dio,
    RuntimeModelPathResolver? pathResolver,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(hours: 1),
                sendTimeout: const Duration(seconds: 30),
              ),
            ),
       _pathResolver = pathResolver ?? const RuntimeModelPathResolver();

  static const String _tag = 'VOICE_DOWNLOAD';

  final Dio _dio;
  final RuntimeModelPathResolver _pathResolver;

  Future<bool> checkAndRequestPermissions() async {
    logEvent(
      _tag,
      '[PERMISSION_REQUEST_BEGIN] checking storage requirements for voice assets',
    );
    if (!Platform.isAndroid) {
      logEvent(
        _tag,
        '[PERMISSION_REQUEST_RESULT] no runtime storage permission required on this platform',
      );
      return true;
    }

    logEvent(
      _tag,
      '[PERMISSION_REQUEST_RESULT] no runtime storage permission required; '
      'voice assets now use app-private storage to avoid Android 11+ (API 30+) '
      'shared-storage restrictions and Android 13+ (API 33+) media permission limits',
    );
    return true;
  }

  Future<void> downloadModels({
    required Function(double) onProgress,
  }) async {
    final targetDir = await _ensureTargetDirectory();
    logEvent(_tag, '[DOWNLOAD_START] targetDir=${targetDir.path}');
    logEvent(
      _tag,
      '[URL_GENERATION] sttRepository=${AppConstants.sttZipformerEnRepository} '
      'baseUrl=${AppConstants.sttZipformerBaseUrl}',
    );
    final specs = _voiceModelSpecs;

    final totalExpectedBytes = specs.fold<int>(
      0,
      (sum, spec) => sum + spec.expectedBytes,
    );
    var completedExpectedBytes = 0;
    onProgress(0.0);

    for (final spec in specs) {
      final destinationPath = '${targetDir.path}/${spec.fileName}';
      final destinationFile = File(destinationPath);
      logEvent(
        _tag,
        '[URL_RESOLVE] file=${spec.fileName} url=${spec.url}',
      );
      if (await _validateExistingFile(spec, destinationFile)) {
        logEvent(
          _tag,
          '[DOWNLOAD_SKIP] file=${spec.fileName} path=${destinationFile.path}',
        );
        completedExpectedBytes += spec.expectedBytes;
        onProgress(
          (completedExpectedBytes / totalExpectedBytes)
              .clamp(0.0, 1.0)
              .toDouble(),
        );
        continue;
      }

      final tempFile = File('$destinationPath.part');
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      if (await destinationFile.exists()) {
        await destinationFile.delete();
      }

      logEvent(
        _tag,
        '[DOWNLOAD_FILE_BEGIN] file=${spec.fileName} url=${spec.url}',
      );

      try {
        int? serverContentLength;

        await _dio.download(
          spec.url,
          tempFile.path,
          deleteOnError: true,
          onReceiveProgress: (received, total) {
            if (total > 0 && serverContentLength == null) {
              serverContentLength = total;
              logEvent(
                _tag,
                '[DOWNLOAD_CONTENT_LENGTH] file=${spec.fileName} '
                'content-length=$total expectedBytes=${spec.expectedBytes}',
              );
            }
            final denominator = total > 0 ? total : spec.expectedBytes;
            final fileProgress = (received / denominator).clamp(0.0, 1.0);
            final aggregate =
                (completedExpectedBytes + fileProgress * spec.expectedBytes) /
                    totalExpectedBytes;
            onProgress(aggregate.clamp(0.0, 1.0).toDouble());
          },
        );

        final savedBytes = await tempFile.exists() ? await tempFile.length() : 0;
        logEvent(
          _tag,
          '[DOWNLOAD_SAVED_BYTES] file=${spec.fileName} '
          'savedBytes=$savedBytes '
          'serverContentLength=${serverContentLength ?? "unknown"} '
          'expectedBytes=${spec.expectedBytes}',
        );

        await _validateDownloadedFile(spec, tempFile);

        logEvent(
          _tag,
          '[DOWNLOAD_RENAME_BEGIN] temp=${tempFile.path} -> dest=${destinationFile.path}',
        );
        await tempFile.rename(destinationFile.path);
        logEvent(
          _tag,
          '[DOWNLOAD_RENAME_OK] file=${spec.fileName}',
        );

        await _validateDownloadedFile(spec, destinationFile);
        logEvent(
          _tag,
          '[DOWNLOAD_FILE_COMPLETE] file=${spec.fileName} bytes=${spec.expectedBytes} path=${destinationFile.path}',
        );
      } on DioException catch (error) {
        await _cleanupTempFiles(tempFile, destinationFile);
        final statusCode = error.response?.statusCode;
        final message = statusCode == null
            ? 'Download del modello vocale fallito: ${spec.fileName}. ${error.message ?? "Errore di rete"}'
            : 'Download del modello vocale fallito: ${spec.fileName} (HTTP $statusCode).';
        logEvent(_tag, '[DOWNLOAD_FILE_FAIL] file=${spec.fileName} error=$message');
        throw VoiceAssetException(message);
      } on VoiceAssetException catch (error) {
        await _cleanupTempFiles(tempFile, destinationFile);
        logEvent(
          _tag,
          '[DOWNLOAD_FILE_FAIL] file=${spec.fileName} error=${error.message}',
        );
        rethrow;
      } catch (error) {
        await _cleanupTempFiles(tempFile, destinationFile);
        final message =
            'Download del modello vocale fallito: ${spec.fileName}. $error';
        logEvent(_tag, '[DOWNLOAD_FILE_FAIL] file=${spec.fileName} error=$message');
        throw VoiceAssetException(message);
      }

      completedExpectedBytes += spec.expectedBytes;
      onProgress(
        (completedExpectedBytes / totalExpectedBytes)
            .clamp(0.0, 1.0)
            .toDouble(),
      );
    }

    logEvent(
      _tag,
      '[EXTRACTION_COMPLETE] no extraction required for raw voice asset files',
    );
    await validateDownloadedAssets();
    logEvent(_tag, '[DOWNLOAD_COMPLETE] voice assets ready in ${targetDir.path}');
    onProgress(1.0);
  }

  Future<void> validateDownloadedAssets() async {
    logEvent(_tag, '[ASSET_VALIDATION_BEGIN] checking required voice files');
    final missingOrInvalid = <String>[];
    String? resolvedDirectoryPath;

    for (final spec in _voiceModelSpecs) {
      final resolution = await _pathResolver.resolveForRead(
        fileName: spec.fileName,
      );
      final file = await _selectValidDownloadedFile(spec, resolution);
      resolvedDirectoryPath ??= file?.parent.path ?? resolution.privateFile.parent.path;

      final parentExists = file != null && await file.parent.exists();
      if (!parentExists) {
        logEvent(
          _tag,
          '[ASSET_MISSING] file=${spec.fileName} expectedPrivate=${resolution.privateFile.path} expectedPublic=${resolution.publicFile.path}',
        );
        missingOrInvalid.add(spec.fileName);
      }
    }

    if (missingOrInvalid.isNotEmpty) {
      final message =
          'Risorse vocali mancanti o non valide: ${missingOrInvalid.join(", ")}. '
          'Riprova il download dei modelli vocali.';
      logEvent(_tag, '[ASSET_VALIDATION_FAIL] $message');
      throw VoiceAssetException(message);
    }

    logEvent(
      _tag,
      '[ASSET_VALIDATION_COMPLETE] all voice assets available dir=${resolvedDirectoryPath ?? "unknown"}',
    );
  }

  Future<Directory> _ensureTargetDirectory() async {
    final targetDir = await _pathResolver.privateModelsDirectory();
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    return targetDir;
  }

  Future<bool> _validateExistingFile(
    _VoiceModelDownloadSpec spec,
    File file,
  ) async {
    try {
      if (!await file.exists()) {
        return false;
      }
      final length = await file.length();
      // Validazione tollerante: accetta il file se copre almeno l'85% della dimensione attesa.
      // Questo evita blocchi dovuti a variazioni minime sui server remoti o compressioni di rete.
      final minBytes = (spec.expectedBytes * 0.85).toInt();
      return length >= minBytes;
    } catch (_) {
      return false;
    }
  }

  Future<void> _validateDownloadedFile(
    _VoiceModelDownloadSpec spec,
    File file,
  ) async {
    if (!await file.exists()) {
      throw VoiceAssetException(
        'File vocale non trovato dopo il download: ${spec.fileName}.',
      );
    }

    final length = await file.length();
    if (length <= 0) {
      throw VoiceAssetException(
        'File vocale vuoto dopo il download: ${spec.fileName}.',
      );
    }

    final minBytes = (spec.expectedBytes * 0.85).toInt();
    if (length < minBytes) {
      throw VoiceAssetException(
        'File vocale incompleto o corrotto: ${spec.fileName} '
        '($length byte rilevati, attesi circa ${spec.expectedBytes}).',
      );
    }
  }

  Future<File?> _selectValidDownloadedFile(
    _VoiceModelDownloadSpec spec,
    RuntimeModelResolution resolution,
  ) async {
    if (await _validateExistingFile(spec, resolution.privateFile)) {
      return resolution.privateFile;
    }
    if (await _validateExistingFile(spec, resolution.publicFile)) {
      return resolution.publicFile;
    }
    if (await _validateExistingFile(spec, resolution.file)) {
      return resolution.file;
    }
    return null;
  }

  Future<void> _cleanupTempFiles(File tempFile, File destinationFile) async {
    if (await tempFile.exists()) {
      logEvent(
        _tag,
        '[CLEANUP_TEMP] deleting temp file: ${tempFile.path}',
      );
      await tempFile.delete();
    }
    if (await destinationFile.exists()) {
      logEvent(
        _tag,
        '[CLEANUP_DEST] deleting partial destination: ${destinationFile.path}',
      );
      await destinationFile.delete();
    }
  }

  List<_VoiceModelDownloadSpec> get _voiceModelSpecs => const <_VoiceModelDownloadSpec>[
        _VoiceModelDownloadSpec(
          fileName: AppConstants.sttEncoderFile,
          url:
              '${AppConstants.sttZipformerBaseUrl}/encoder-epoch-99-avg-1-chunk-16-left-128.onnx',
          expectedBytes: 170 * 1024 * 1024,
        ),
        _VoiceModelDownloadSpec(
          fileName: AppConstants.sttDecoderFile,
          url:
              '${AppConstants.sttZipformerBaseUrl}/decoder-epoch-99-avg-1-chunk-16-left-128.onnx',
          expectedBytes: 400 * 1024,
        ),
        _VoiceModelDownloadSpec(
          fileName: AppConstants.sttJoinerFile,
          url:
              '${AppConstants.sttZipformerBaseUrl}/joiner-epoch-99-avg-1-chunk-16-left-128.onnx',
          expectedBytes: 18 * 1024 * 1024,
        ),
        _VoiceModelDownloadSpec(
          fileName: AppConstants.sttTokensFile,
          url: '${AppConstants.sttZipformerBaseUrl}/tokens.txt',
          expectedBytes: 7 * 1024,
        ),
        _VoiceModelDownloadSpec(
          fileName: AppConstants.ttsModelFile,
          url: 'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/vits-tts-it-paola.onnx',
          expectedBytes: 120 * 1024 * 1024,
        ),
        _VoiceModelDownloadSpec(
          fileName: AppConstants.ttsLexiconFile,
          url: 'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/lexicon.txt',
          expectedBytes: 1 * 1024 * 1024,
        ),
        _VoiceModelDownloadSpec(
          fileName: AppConstants.ttsTokensFile,
          url: 'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/tokens.txt',
          expectedBytes: 85 * 1024,
        ),
      ];
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
