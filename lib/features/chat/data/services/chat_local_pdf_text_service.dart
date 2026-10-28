import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Explicitly user-selected PDF extraction. Never sends file or text to Cloud.
abstract interface class PdfOfflineTextReader {
  Future<String> readPdf(String path);
}

final class AndroidPdfOfflineTextReader implements PdfOfflineTextReader {
  AndroidPdfOfflineTextReader({
    MethodChannel? channel,
    bool? androidSupported,
  })  : _channel = channel ??
            const MethodChannel('com.aiorchestrator/local_pdf_text'),
        _supported = androidSupported ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final bool _supported;

  @override
  Future<String> readPdf(String path) async {
    if (!_supported) {
      throw StateError(
        'File PDF: lettura locale non disponibile su questa piattaforma. '
        'Per ora usa TXT. Nessun documento è stato inviato al Cloud.',
      );
    }
    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'extractText',
        <String, String>{'path': path},
      ).timeout(const Duration(seconds: 90));
      final text = response?['text'];
      if (text is! String || text.trim().isEmpty ||
          text.length > 16000 || text.contains('\u0000')) {
        throw StateError(
          'File PDF: nessun testo locale affidabile estratto.',
        );
      }
      return text;
    } on TimeoutException {
      throw StateError(
        'File PDF: lettura locale troppo lenta. Usa un PDF più corto.',
      );
    } on MissingPluginException {
      throw StateError(
        'File PDF: lettura offline non disponibile in questa build.',
      );
    } on PlatformException catch (error) {
      // Native messages are safe, fixed strings; never log paths or contents.
      throw StateError(
        'File PDF: ${error.message ?? 'lettura locale non riuscita.'}',
      );
    }
  }
}
