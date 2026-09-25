import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:ai_orchestrator/core/memory/context_window_manager.dart';
import 'package:ai_orchestrator/features/chat_memory/conversation_memory_service.dart';

enum AssistantDataResetCategory {
  recentContext,
  chatHistory,
  semanticChatIndex,
  durableMemory,
  projectMemory,
}

final class AssistantDataResetSelection {
  const AssistantDataResetSelection({
    this.recentContext = false,
    this.chatHistory = false,
    this.semanticChatIndex = false,
    this.durableMemory = false,
    this.projectMemory = false,
  });

  const AssistantDataResetSelection.all()
      : recentContext = true,
        chatHistory = true,
        semanticChatIndex = true,
        durableMemory = true,
        projectMemory = true;

  final bool recentContext;
  final bool chatHistory;
  final bool semanticChatIndex;
  final bool durableMemory;
  final bool projectMemory;

  bool get isEmpty =>
      !recentContext &&
      !chatHistory &&
      !semanticChatIndex &&
      !durableMemory &&
      !projectMemory;

  bool get isAll =>
      recentContext &&
      chatHistory &&
      semanticChatIndex &&
      durableMemory &&
      projectMemory;

  bool includes(AssistantDataResetCategory category) => switch (category) {
        AssistantDataResetCategory.recentContext => recentContext,
        AssistantDataResetCategory.chatHistory => chatHistory,
        AssistantDataResetCategory.semanticChatIndex => semanticChatIndex,
        AssistantDataResetCategory.durableMemory => durableMemory,
        AssistantDataResetCategory.projectMemory => projectMemory,
      };
}

final class AssistantDataResetOutcome {
  const AssistantDataResetOutcome({
    required this.category,
    required this.success,
    this.removedItems,
    this.error,
  });

  final AssistantDataResetCategory category;
  final bool success;
  final int? removedItems;
  final String? error;
}

final class AssistantDataResetReport {
  AssistantDataResetReport(Iterable<AssistantDataResetOutcome> outcomes)
      : outcomes = List<AssistantDataResetOutcome>.unmodifiable(outcomes);

  final List<AssistantDataResetOutcome> outcomes;

  bool get complete => outcomes.isNotEmpty && outcomes.every((item) => item.success);

  bool get partial =>
      outcomes.any((item) => item.success) &&
      outcomes.any((item) => !item.success);

  AssistantDataResetOutcome? outcomeFor(AssistantDataResetCategory category) {
    for (final outcome in outcomes) {
      if (outcome.category == category) return outcome;
    }
    return null;
  }
}

/// Destructive Settings-only reset coordinator.
///
/// The service is deliberately narrow: it erases Assistant memory categories
/// only. Models, downloaded assets, credentials, runtime/provider selection and
/// project source files are outside this boundary.
final class AssistantDataResetService {
  const AssistantDataResetService({
    required DatabaseHelper databaseHelper,
    required ConversationMemoryService conversationMemoryService,
    required ContextWindowManager contextWindowManager,
  })  : _databaseHelper = databaseHelper,
        _conversationMemoryService = conversationMemoryService,
        _contextWindowManager = contextWindowManager;

  final DatabaseHelper _databaseHelper;
  final ConversationMemoryService _conversationMemoryService;
  final ContextWindowManager _contextWindowManager;

  Future<AssistantDataResetReport> reset(
    AssistantDataResetSelection selection,
  ) async {
    if (selection.isEmpty) {
      throw ArgumentError('At least one Assistant data category is required.');
    }

    return _conversationMemoryService.runWithGlobalResetBarrier(() async {
      final outcomes = <AssistantDataResetOutcome>[];

      if (selection.recentContext) {
        try {
          _contextWindowManager.startNewSession();
          outcomes.add(
            const AssistantDataResetOutcome(
              category: AssistantDataResetCategory.recentContext,
              success: true,
            ),
          );
        } on Object catch (error) {
          outcomes.add(
            AssistantDataResetOutcome(
              category: AssistantDataResetCategory.recentContext,
              success: false,
              error: error.toString(),
            ),
          );
        }
      }

      if (selection.chatHistory) {
        outcomes.add(
          await _eraseRows(
            AssistantDataResetCategory.chatHistory,
            _databaseHelper.deleteAllChatMessages,
          ),
        );
      }

      if (selection.semanticChatIndex) {
        outcomes.add(
          await _eraseRows(
            AssistantDataResetCategory.semanticChatIndex,
            _databaseHelper.deleteAllChatSemanticMemory,
          ),
        );
      }

      if (selection.durableMemory) {
        outcomes.add(
          await _eraseRows(
            AssistantDataResetCategory.durableMemory,
            () => _databaseHelper.deletePreferencesWithPrefix(
              AssistantDurableMemoryStore.storagePrefix,
            ),
          ),
        );
      }

      if (selection.projectMemory) {
        outcomes.add(
          await _eraseRows(
            AssistantDataResetCategory.projectMemory,
            _databaseHelper.deleteAllProjectMemories,
          ),
        );
      }

      return AssistantDataResetReport(outcomes);
    });
  }

  Future<AssistantDataResetOutcome> _eraseRows(
    AssistantDataResetCategory category,
    Future<int> Function() operation,
  ) async {
    try {
      final removed = await operation();
      return AssistantDataResetOutcome(
        category: category,
        success: true,
        removedItems: removed,
      );
    } on Object catch (error) {
      return AssistantDataResetOutcome(
        category: category,
        success: false,
        error: error.toString(),
      );
    }
  }
}
