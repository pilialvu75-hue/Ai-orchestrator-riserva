import 'package:ai_orchestrator/core/config/ai/assistant_reply_language_policy.dart';
import 'package:ai_orchestrator/core/config/ai/assistant_system_prompt_service.dart';
import 'package:ai_orchestrator/core/config/ai/system_prompt_config.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_natural_memory_consent_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/verified_memory_action_writer.dart';

/// Thin decorator that keeps Assistant prompt preference resolution outside the
/// persistence/runtime implementation.
///
/// All chat behavior is delegated unchanged except [sendMessage], where the
/// ordinary Assistant prompt marker is replaced with the user's configured
/// prompt before Local/Cloud routing begins.
class PromptResolvingChatRepository implements ChatRepository, VerifiedMemoryActionWriter {
  const PromptResolvingChatRepository({
    required ChatRepository delegate,
    required AssistantSystemPromptService systemPromptService,
    required AssistantDurableMemoryContextService durableMemoryContextService,
    required AiRuntimeMode Function() runtimeMode,
    AssistantDurableMemoryCaptureService? durableMemoryCaptureService,
    AssistantNaturalMemoryConsentService? naturalMemoryConsentService,
  })  : _delegate = delegate,
        _systemPromptService = systemPromptService,
        _durableMemoryContextService = durableMemoryContextService,
        _runtimeMode = runtimeMode,
        _durableMemoryCaptureService = durableMemoryCaptureService,
        _naturalMemoryConsentService = naturalMemoryConsentService;

  final ChatRepository _delegate;
  final AssistantSystemPromptService _systemPromptService;
  final AssistantDurableMemoryContextService _durableMemoryContextService;
  final AiRuntimeMode Function() _runtimeMode;
  final AssistantDurableMemoryCaptureService? _durableMemoryCaptureService;
  final AssistantNaturalMemoryConsentService? _naturalMemoryConsentService;

  @override
  Future<ChatMessage> persistVerifiedMemoryAction({
    required String sessionId,
    required String userPrompt,
    required String acknowledgement,
    void Function(String partialText)? onPartialResponse,
  }) {
    final delegate = _delegate;
    if (delegate is! VerifiedMemoryActionWriter) {
      throw StateError('The chat backend cannot persist memory actions.');
    }
    return (delegate as VerifiedMemoryActionWriter).persistVerifiedMemoryAction(
      sessionId: sessionId,
      userPrompt: userPrompt,
      acknowledgement: acknowledgement,
      onPartialResponse: onPartialResponse,
    );
  }

  String _memoryAcknowledgement(AssistantMemoryCommandResult result) {
    return switch (result.status) {
      AssistantMemoryCommandStatus.saved =>
        'Ho salvato il ricordo nella memoria locale di Aivexus.',
      AssistantMemoryCommandStatus.forgotten =>
        'Ho eliminato il ricordo richiesto dalla memoria locale di Aivexus. '
            'La cronologia delle chat non è stata cancellata.',
      AssistantMemoryCommandStatus.notFound =>
        'Non ho trovato ricordi espliciti corrispondenti nella memoria locale. '
            'Non ho cancellato altri dati.',
      AssistantMemoryCommandStatus.confirmationRequired =>
        'Per cancellare tutti i ricordi espliciti locali su questo argomento, '
            'invia: "Confermo: dimentica tutto su ${result.topic}". '
            'Le chat e le altre conoscenze resteranno intatte.',
      AssistantMemoryCommandStatus.topicForgotten =>
        'Ho eliminato ${result.count} ricordi espliciti locali relativi '
            'all’argomento richiesto. Non ho cancellato chat o progetti.',
      AssistantMemoryCommandStatus.invalid =>
        'Non ho modificato la memoria: la richiesta non è valida '
            'o non è riconosciuta come istruzione di memoria.',
      AssistantMemoryCommandStatus.blocked =>
        'La memoria locale è temporaneamente indisponibile: '
            'non posso confermare modifiche.',
      AssistantMemoryCommandStatus.notInstruction => '',
    };
  }

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) =>
      _delegate.getMessages(sessionId);

  @override
  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments = const <ChatAttachment>[],
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) async {
    final isOrdinary =
        _systemPromptService.isOrdinaryAssistantRequest(systemPrompt);
    // The app's local memory service is the authoritative writer.
    // An explicit instruction receives a real, persisted acknowledgement,
    // without asking any Local/Hybrid/Cloud model to hallucinate the result.
    if (isOrdinary &&
        attachments.isEmpty &&
        _durableMemoryCaptureService != null) {
      final AssistantMemoryCommandResult result;
      try {
        result = await _durableMemoryCaptureService
            .applyExplicitUserInstructionResult(
          sessionId: sessionId,
          userPrompt: userPrompt,
        );
      } catch (_) {
        // No model may claim the operation succeeded after a storage failure.
        onRuntimeNotice?.call(
          'Non è stato possibile verificare la modifica della memoria locale.',
        );
        rethrow;
      }

      if (result.isInstruction) {
        return persistVerifiedMemoryAction(
          sessionId: sessionId,
          userPrompt: userPrompt,
          acknowledgement: _memoryAcknowledgement(result),
          onPartialResponse: onPartialResponse,
        );
      }
    }

    // The owner can explicitly enable *proposal staging* in Settings.
    // Recognize only direct, attachment-free ordinary user messages. Never
    // confirm a candidate here, attach it to Cloud/Hybrid prompts or allow a
    // worker/model/attachment to masquerade as the owner. An extraction/storage
    // error must not prevent the normal conversational response.
    final consent = _naturalMemoryConsentService;
    if (isOrdinary &&
        attachments.isEmpty &&
        _durableMemoryCaptureService != null &&
        consent != null &&
        consent.enabled) {
      try {
        final nameProposed =
            await _durableMemoryCaptureService.proposeNaturalUserNameCandidate(
          sessionId: sessionId,
          userPrompt: userPrompt,
          consentEnabled: true,
          directUserMessage: true,
          consentStillEnabled: () => consent.enabled,
        );
        if (!nameProposed) {
          final carColorProposed =
              await _durableMemoryCaptureService
                  .proposeNaturalUserCarColorCandidate(
            sessionId: sessionId,
            userPrompt: userPrompt,
            consentEnabled: true,
            directUserMessage: true,
            consentStillEnabled: () => consent.enabled,
          );
          if (!carColorProposed) {
            await _durableMemoryCaptureService
                .proposeNaturalUserCarColorCorrectionCandidate(
              sessionId: sessionId,
              userPrompt: userPrompt,
              consentEnabled: true,
              directUserMessage: true,
              consentStillEnabled: () => consent.enabled,
            );
          }
        }
      } catch (_) {
        onRuntimeNotice?.call(
          'Non è stato possibile aggiungere la proposta di memoria locale.',
        );
      }
    }

    final resolvedPrompt = _systemPromptService.resolveForIncoming(systemPrompt);
    // Personal confirmed memories stay on device by default. Cloud and
    // hybrid routing can forward system prompts to external providers;
    // do not include private memory there before a separate consent gate.
    final promptWithMemory = isOrdinary && _runtimeMode() == AiRuntimeMode.local
        ? await _durableMemoryContextService.augmentSystemPrompt(
            baseSystemPrompt: resolvedPrompt,
            sessionId: sessionId,
            userPrompt: userPrompt,
          )
        : resolvedPrompt;

    // Hint only the stock conversational Assistant. Never override a
    // user-authored fixed-language prompt or specialized worker instructions.
    // This is a per-turn hint, not a stored user preference.
    final effectivePrompt = isOrdinary &&
            _systemPromptService.currentPrompt == SystemPromptConfig.defaultPrompt
        ? AssistantReplyLanguagePolicy.withCurrentTurnHint(
            systemPrompt: promptWithMemory,
            userPrompt: userPrompt,
          )
        : promptWithMemory;

    return _delegate.sendMessage(
      sessionId: sessionId,
      userPrompt: userPrompt,
      systemPrompt: effectivePrompt,
      attachments: attachments,
      onPartialResponse: onPartialResponse,
      onRuntimeNotice: onRuntimeNotice,
    );
  }

  @override
  Future<int> pruneHistory({
    int maxAgeDays = AppConstants.chatHistoryMaxAgeDays,
    int maxRows = AppConstants.chatHistoryMaxRows,
  }) {
    return _delegate.pruneHistory(
      maxAgeDays: maxAgeDays,
      maxRows: maxRows,
    );
  }

  @override
  Future<void> clearSession(String sessionId) =>
      _delegate.clearSession(sessionId);

  @override
  Future<int> deleteMessagesFrom(
    String sessionId,
    String messageId,
  ) {
    return _delegate.deleteMessagesFrom(sessionId, messageId);
  }
}
