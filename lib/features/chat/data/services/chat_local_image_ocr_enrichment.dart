import 'dart:async';

import 'package:cantiere_local_image_vision/cantiere_local_image_vision.dart';
import 'package:flutter/services.dart';

/// Adds text *observed on device* to offline image categories.
/// Uses a separate bundled OCR model; no image, prompt or text goes to Cloud.
final class ChatLocalImageOcrEnrichment {
  ChatLocalImageOcrEnrichment({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('com.aiorchestrator/local_image_text');

  final MethodChannel _channel;
  static const int maxOutputChars = 1800;

  Future<ChatLocalOcrResult> enrich({
    required String imagePath,
    required String prompt,
    required LocalImageLabelResult labels,
  }) async {
    if (!shouldRun(prompt: prompt, labels: labels)) {
      return ChatLocalOcrResult(text: labels.text, hasText: false);
    }
    try {
      // Only the image path reaches native OCR, never the user's question.
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'readText',
        <String, String>{'path': imagePath},
      ).timeout(const Duration(seconds: 20));
      final raw = response?['text'];
      final value = raw is String ? raw.trim() : '';
      if (value.isEmpty) {
        return ChatLocalOcrResult(
          text: labels.text + '\nOCR locale: nessuna scritta leggibile identificata.',
          hasText: false,
        );
      }

      // Reword the labeler's "no OCR" disclaimer only when OCR actually worked.
      final categories = labels.text
          .replaceAll('colori, quantità, testo o altri dettagli',
              'colori, quantità o altri dettagli')
          .replaceAll('dettagli, colori o testo', 'dettagli o colori');
      final displayed = value.length > maxOutputChars
          ? value.substring(0, maxOutputChars)
          : value;
      final truncated = response?['truncated'] == true ||
          value.length > maxOutputChars;
      return ChatLocalOcrResult(
        hasText: true,
        text: categories +
            '\n\nTesto riconosciuto nella foto (OCR offline; accenti e lettere '
            'potrebbero contenere errori):\n' +
            displayed +
            (truncated ? '\n[Testo abbreviato]' : ''),
      );
    } on TimeoutException {
      return ChatLocalOcrResult(
        text: labels.text + '\nOCR locale interrotto per timeout; categorie disponibili.',
        hasText: false,
      );
    } on MissingPluginException {
      return ChatLocalOcrResult(
        text: labels.text + '\nOCR locale non disponibile in questa build.',
        hasText: false,
      );
    } on PlatformException {
      return ChatLocalOcrResult(
        text: labels.text + '\nLettura OCR locale non riuscita; categorie disponibili.',
        hasText: false,
      );
    }
  }

  static bool shouldRun({
    required String prompt,
    required LocalImageLabelResult labels,
  }) {
    const textCategories = <String>{
      'poster', 'document', 'text', 'sign', 'book', 'newspaper',
      'paper', 'screenshot', 'advertisement', 'billboard',
      'magazine', 'flyer', 'menu', 'whiteboard',
    };
    if (labels.labels.any(
        (label) => textCategories.contains(label.name.toLowerCase()))) {
      return true;
    }
    final request = prompt.toLowerCase();
    return <String>[
      'testo', 'scritta', 'scritt', 'leggi', 'trascrivi', 'cartello',
      'manifesto', 'documento', 'parole', 'lettere', 'ocr',
      'read text', 'written', 'poster', 'texte', 'écrit',
      'lire', 'tradu', 'traduci', 'translate',
    ].any(request.contains);
  }
}

final class ChatLocalOcrResult {
  const ChatLocalOcrResult({required this.text, required this.hasText});
  final String text;
  final bool hasText;
}
