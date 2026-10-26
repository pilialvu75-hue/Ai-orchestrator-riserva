import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_preferences.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_response_model.dart';
import 'package:http/http.dart' as http;

/// A single vision result, identified by the actual provider used.
class ChatImageVisionResult {
  const ChatImageVisionResult({
    required this.text,
    required this.providerId,
  });
  final String text;
  final String providerId;
}

/// Independent boundary so production uses a real image-capable request and
/// tests never need external credentials or network access.
abstract interface class ChatImageVisionService {
  Future<ChatImageVisionResult> analyze({
    required String providerId,
    required ChatAttachment image,
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[],
  });
}

/// Explicit Cloud-only Image support. No implicit provider switching,
/// no image URL exposure, and no fallback to text-only local inference.
final class CloudChatImageVisionService implements ChatImageVisionService {
  CloudChatImageVisionService({
    http.Client? client,
    String? Function(String)? credentialFor,
    String? Function(String)? modelFor,
  })  : _client = client ?? http.Client(),
        _credentialFor =
            credentialFor ?? CloudCredentialStore.instance.secretFor,
        _modelFor =
            modelFor ?? CloudRuntimePreferences.instance.modelForProvider;

  static const int maxImageBytes = 8 * 1024 * 1024;
  static const Duration requestTimeout = Duration(seconds: 45);

  final http.Client _client;
  final String? Function(String) _credentialFor;
  final String? Function(String) _modelFor;

  @override
  Future<ChatImageVisionResult> analyze({
    required String providerId,
    required ChatAttachment image,
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[],
  }) async {
    if (providerId != 'openAi' && providerId != 'gemini') {
      throw StateError(
        'Image supporta per ora solo OpenAI e Gemini selezionati '
        'manualmente in modalità Cloud.',
      );
    }
    if (!image.isImage ||
        image.uploadState != ChatAttachmentUploadState.ready ||
        image.path.trim().isEmpty) {
      throw StateError('Immagine non disponibile o ancora in preparazione.');
    }

    final credential = _credentialFor(providerId)?.trim() ?? '';
    if (credential.isEmpty) {
      throw StateError('Configura la chiave Cloud per $providerId prima di usare Image.');
    }
    final imageFile = File(image.path);
    if (!await imageFile.exists()) {
      throw StateError('Immagine originale non trovata: selezionala di nuovo.');
    }
    final length = await imageFile.length();
    if (length <= 0 || length > maxImageBytes) {
      throw StateError('Image accetta file di massimo 8 MB.');
    }
    final bytes = await imageFile.readAsBytes();
    final mimeType = detectImageMime(bytes);
    if (mimeType == null) {
      throw StateError('Formato Image non valido: usare JPEG, PNG o WebP.');
    }

    final userQuestion = prompt.trim().isEmpty
        ? 'Descrivi questa immagine, senza inventare dettagli non visibili.'
        : prompt.trim();
    final history = context
        .where((turn) => !turn.excludeFromContext &&
            turn.role != ChatRole.system &&
            turn.content.trim().isNotEmpty)
        .toList(growable: false);
    final recent = history.length > 6
        ? history.sublist(history.length - 6)
        : history;
    final model = _modelFor(providerId)?.trim();
    final selectedModel = model == null || model.isEmpty
        ? (providerId == 'openAi' ? 'gpt-4o' : 'gemini-3.8-flash')
        : model;
    final encodedImage = base64Encode(bytes);
    final isOpenAi = providerId == 'openAi';

    final Map<String, dynamic> payload;
    final Uri endpoint;
    final Map<String, String> headers;
    if (isOpenAi) {
      endpoint = Uri.parse('${AppConstants.openAiBaseUrl}/chat/completions');
      headers = <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $credential',
      };
      payload = <String, dynamic>{
        'model': selectedModel,
        'max_tokens': 1024,
        'messages': <Map<String, dynamic>>[
          if (systemPrompt?.trim().isNotEmpty ?? false)
            <String, dynamic>{
              'role': 'system',
              'content': systemPrompt!.trim(),
            },
          ...recent.map((turn) => <String, dynamic>{
                'role': turn.role == ChatRole.assistant ? 'assistant' : 'user',
                'content': turn.content,
              }),
          <String, dynamic>{
            'role': 'user',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': userQuestion},
              <String, dynamic>{
                'type': 'image_url',
                'image_url': <String, String>{
                  'url': 'data:$mimeType;base64,$encodedImage',
                  'detail': 'low',
                },
              },
            ],
          },
        ],
      };
    } else {
      endpoint = Uri.parse('${AppConstants.geminiBaseUrl}/models/$selectedModel:generateContent');
      headers = <String, String>{
        'Content-Type': 'application/json',
        'x-goog-api-key': credential,
      };
      payload = <String, dynamic>{
        if (systemPrompt?.trim().isNotEmpty ?? false)
          'systemInstruction': <String, dynamic>{
            'parts': <Map<String, String>>[
              <String, String>{'text': systemPrompt!.trim()},
            ],
          },
        'contents': <Map<String, dynamic>>[
          ...recent.map((turn) => <String, dynamic>{
                'role': turn.role == ChatRole.assistant ? 'model' : 'user',
                'parts': <Map<String, String>>[
                  <String, String>{'text': turn.content},
                ],
              }),
          <String, dynamic>{
            'role': 'user',
            'parts': <Map<String, dynamic>>[
              <String, String>{'text': userQuestion},
              <String, dynamic>{
                'inlineData': <String, String>{
                  'mimeType': mimeType,
                  'data': encodedImage,
                },
              },
            ],
          },
        ],
        'generationConfig': const <String, dynamic>{
          'maxOutputTokens': 1024,
        },
      };
    }

    // Credentials and image bytes must never be included in diagnostics.
    final response = await _client
        .post(endpoint, headers: headers, body: jsonEncode(payload))
        .timeout(requestTimeout);
    if (response.statusCode != 200) {
      throw StateError(
        'Analisi Image non riuscita ($providerId, HTTP ${response.statusCode}). '
        'Controlla modello, credenziali e limiti del provider.',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Risposta del servizio Image non valida.');
    }
    final result = isOpenAi
        ? AiResponseModel.fromOpenAiJson(decoded)
        : AiResponseModel.fromGeminiJson(decoded);
    if (result.text.trim().isEmpty) {
      throw StateError('Il modello visivo non ha restituito una descrizione.');
    }
    return ChatImageVisionResult(
      text: result.text.trim(),
      providerId: providerId,
    );
  }

  /// Rejects renamed/non-image files before exposing bytes to a Cloud provider.
  static String? detectImageMime(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
        String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP') {
      return 'image/webp';
    }
    return null;
  }
}
