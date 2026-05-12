import 'package:uuid/uuid.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/orchestrator.dart';
import 'package:ai_orchestrator/core/runtime/inference/stream_text_accumulator.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/data/models/chat_message_model.dart';

class ChatRepositoryImpl implements ChatRepository {
  ChatRepositoryImpl({
    required this.localDataSource,
    required this.orchestrator,
  });

  final ChatLocalDataSource localDataSource;
  final Orchestrator orchestrator;

  static final _uuid = Uuid();

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    try {
      final messages = await localDataSource.getMessages(sessionId);
      return messages;
    } on DatabaseException catch (e) {
      throw DatabaseFailure(e.message);
    } catch (e) {
      throw DatabaseFailure(e.toString());
    }
  }

  @override
  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments = const <ChatAttachment>[],
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) async {
    try {
      final normalizedPrompt = userPrompt.trim();
      final userMsg = ChatMessageModel(
        id: _uuid.v4(),
        sessionId: sessionId,
        role: 'user',
        content: normalizedPrompt,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        attachments: attachments,
      );
      await localDataSource.insertMessage(userMsg);

      if (normalizedPrompt.isEmpty && attachments.isNotEmpty) {
        return userMsg;
      }

      final sessionMessages = await localDataSource.getMessages(sessionId);
      final context = sessionMessages
          .where((m) => m.id != userMsg.id)
          .map((m) => '${m.role}: ${m.content}')
          .toList(growable: false);

      final streamedResponse = StringBuffer();
      String responseProvider = 'local';

      await for (final chunk in orchestrator.handleStream(
        normalizedPrompt,
        sessionId: sessionId,
        context: context,
        systemPrompt: systemPrompt,
      )) {
        if (chunk.runtimeNotice != null && chunk.runtimeNotice!.trim().isNotEmpty) {
          onRuntimeNotice?.call(chunk.runtimeNotice!);
          continue;
        }
        if (chunk.isError) {
          throw ServerFailure(
            _normalizeRuntimeErrorMessage(
              chunk.errorMessage ?? 'Inference failed.',
            ),
          );
        }
        if (chunk.isFinal) {
          if (chunk.text.isNotEmpty) {
            final merged = mergeStreamedText(
              currentText: streamedResponse.toString(),
              incomingText: chunk.text,
              isFinalChunk: true,
            );
            streamedResponse.clear();
            streamedResponse.write(merged);
          }
          if (chunk.model != null && chunk.model!.trim().isNotEmpty) {
            responseProvider = chunk.model!;
          }
        } else {
          streamedResponse.write(chunk.text);
          onPartialResponse?.call(streamedResponse.toString());
        }
      }

      final responseText = streamedResponse.toString().trim();
      if (responseText.isEmpty) {
        throw const ServerFailure('Inference returned an empty response.');
      }

      final assistantMsg = ChatMessageModel(
        id: _uuid.v4(),
        sessionId: sessionId,
        role: 'assistant',
        content: responseText,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        provider: responseProvider,
      );
      await localDataSource.insertMessage(assistantMsg);
      return assistantMsg;
    } on DatabaseException catch (e) {
      throw DatabaseFailure(e.message);
    } on ServerException catch (e) {
      throw ServerFailure(e.message);
    } on Failure {
      rethrow;
    } catch (e) {
      throw ServerFailure(e.toString());
    }
  }

  @override
  Future<int> pruneHistory({
    int maxAgeDays = AppConstants.chatHistoryMaxAgeDays,
    int maxRows = AppConstants.chatHistoryMaxRows,
  }) async {
    try {
      final cutoff =
          DateTime.now().subtract(Duration(days: maxAgeDays));
      int deleted = await localDataSource.deleteOldMessages(cutoff);
      final remaining = await localDataSource.countMessages();
      if (remaining > maxRows) {
        deleted += await localDataSource.deleteExcessMessages(maxRows);
      }
      return deleted;
    } on DatabaseException catch (e) {
      throw DatabaseFailure(e.message);
    } catch (e) {
      throw DatabaseFailure(e.toString());
    }
  }

  @override
  Future<void> clearSession(String sessionId) async {
    try {
      await localDataSource.clearSession(sessionId);
    } on DatabaseException catch (e) {
      throw DatabaseFailure(e.message);
    } catch (e) {
      throw DatabaseFailure(e.toString());
    }
  }

  static String _normalizeRuntimeErrorMessage(String input) {
    const prefix = 'AI_RUNTIME_ERROR|';
    final raw = input.trim();
    if (!raw.startsWith(prefix)) return raw;

    final payload = raw.substring(prefix.length);
    final parts = payload.split('|');
    String? stage;
    String? message;
    String? details;
    for (final part in parts) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final key = part.substring(0, idx).trim().toLowerCase();
      final value = part.substring(idx + 1).trim();
      if (value.isEmpty) continue;
      if (key == 'stage') stage = value;
      if (key == 'message') message = value;
      if (key == 'details') details = value;
    }

    final buffer = StringBuffer();
    buffer.write(message ?? 'Local runtime failed.');
    if (details != null && details.isNotEmpty) {
      buffer.write('\nDetails: $details');
    }
    if (stage != null && stage.isNotEmpty) {
      buffer.write('\nStage: $stage');
    }
    return buffer.toString();
  }
}
