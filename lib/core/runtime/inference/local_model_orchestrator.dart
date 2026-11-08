import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';

/// Selects only already-installed, validated and runtime-compatible GGUFs.
///
/// Applies measured-device safety gates and bounded session affinity. No prompt
/// rewriting, cloud access, model downloads or changes to MANUAL selection.
class LocalModelOrchestrator {
  const LocalModelOrchestrator();

  AiModel? select({
    required InferenceRequest request,
    required Iterable<AiModel> availableModels,
    required AiModel? preferredModel,
    required bool Function(AiModel) supportsModel,
    ResourceSample? resources,
    bool isAndroid = false,
    String? lastCompletedModelId,
    int successfulTurnsSinceSwitch = 99,
  }) => decide(
    request: request,
    availableModels: availableModels,
    preferredModel: preferredModel,
    supportsModel: supportsModel,
    resources: resources,
    isAndroid: isAndroid,
    lastCompletedModelId: lastCompletedModelId,
    successfulTurnsSinceSwitch: successfulTurnsSinceSwitch,
  ).model;

  LocalModelRoutingDecision decide({
    required InferenceRequest request,
    required Iterable<AiModel> availableModels,
    required AiModel? preferredModel,
    required bool Function(AiModel) supportsModel,
    ResourceSample? resources,
    bool isAndroid = false,
    String? lastCompletedModelId,
    int successfulTurnsSinceSwitch = 99,
  }) {
    final task = classify(request);
    final eligible = availableModels.where((model) =>
        model.isDownloaded &&
        model.validationStatus == ModelValidationStatus.validatedOk &&
        (model.localPath?.trim().isNotEmpty ?? false) &&
        supportsModel(model)).toList(growable: false);
    if (eligible.isEmpty) {
      return LocalModelRoutingDecision(null, task, LocalModelRoutingReason.noEligible, 0);
    }

    // Do not choose a larger resident model during Android low-memory pressure.
    // Unknown telemetry is not evidence that a large model is safe.
    final total = resources?.totalBytes;
    final phoneWithLimitedRam = isAndroid &&
        (total == null || total <= 8 * 1024 * 1024 * 1024);
    final pressured = isAndroid && (resources?.pressured ?? false);
    final safe = eligible.where((model) {
      if (!isAndroid) return true;
      if (pressured) return model.sizeBytes <= 1900000000;
      if (phoneWithLimitedRam) return model.sizeBytes <= 2800000000;
      return true;
    }).toList(growable: false);
    // If only large models exist on a memory-pressured phone, do not
    // deliberately trigger an OOM. The selected model remains untouched.
    if (safe.isEmpty) {
      return LocalModelRoutingDecision(null, task, LocalModelRoutingReason.memoryGuard, 0);
    }

    // Only models still present, validated and safe may retain affinity.
    // A missing/uninstalled model is never pinned by stale session state.
    AiModel? current;
    if (lastCompletedModelId != null) {
      for (final candidate in safe) {
        if (candidate.id == lastCompletedModelId) {
          current = candidate;
          break;
        }
      }
    }
    final preferredId = current?.id ?? preferredModel?.id;
    final prompt = request.prompt.toLowerCase();
    final multilingual = RegExp(
      r'\b(traduci|traduire|translate|traducir|fran[cç]ais|francese|'
      r'espa[nñ]ol|spagnolo|italiano|italien|multilingu|language)\b',
      caseSensitive: false,
    ).hasMatch(prompt);

    int score(AiModel model) {
      final id = '${model.id} ${model.effectiveRuntimeModelId} '
          '${model.displayName} ${model.detectedFamily ?? ''}'
          .toLowerCase();
      var result = 0;
      // Stability wins for ordinary dialogue; special tasks may justify a
      // model reload, but small capability differences should not.
      if (model.id == preferredId) {
        result += task == LocalConversationTask.general && !multilingual ? 40 : 7;
      }
      if (id.contains('qwen')) {
        result += 12;
        if (task == LocalConversationTask.coding) result += 30;
        if (task == LocalConversationTask.reasoning) result += 9;
        if (multilingual) result += 22;
      }
      if (id.contains('phi')) {
        result += 10;
        if (task == LocalConversationTask.reasoning) result += 27;
        if (task == LocalConversationTask.coding) result += 10;
      }
      if (id.contains('nemotron')) {
        result += 11;
        if (task == LocalConversationTask.reasoning) result += 30;
      }
      if (id.contains('coder') || id.contains('codegemma') ||
          id.contains('codestral')) {
        if (task == LocalConversationTask.coding) result += 38;
      }
      if (id.contains('llama') || id.contains('gemma')) result += 8;
      // Avoid repeatedly choosing a memory-intensive model for a very small
      // capability gain on phones. On desktop the user's hardware has priority.
      if (isAndroid) {
        result -= model.sizeBytes ~/ 700000000;
        if (resources?.pressured ?? false) {
          result -= model.sizeBytes ~/ 200000000;
        }
      }
      return result;
    }

    safe.sort((a, b) {
      final difference = score(b).compareTo(score(a));
      if (difference != 0) return difference;
      if (a.id == preferredId) return -1;
      if (b.id == preferredId) return 1;
      return a.id.compareTo(b.id);
    });
    final best = safe.first;
    if (current == null) {
      return LocalModelRoutingDecision(
        best,
        task,
        lastCompletedModelId == null
            ? LocalModelRoutingReason.initial
            : LocalModelRoutingReason.previousUnavailable,
        0,
      );
    }
    if (current.id == best.id) {
      return LocalModelRoutingDecision(
          current, task, LocalModelRoutingReason.keptBest, 0);
    }

    // Short elliptical replies preserve a consistent speaker/model even
    // when task classification inherits a previous specialist topic.
    final trimmed = request.prompt.trim().toLowerCase();
    final followUp = RegExp(
      r'^(continua|continue|continuer|prosegui|ancora|again|'
      r'e poi\??|e per (lui|lei)\??|et ensuite\??|go on|more)\s*[.!?]*$',
      caseSensitive: false,
    ).hasMatch(trimmed);
    if (followUp) {
      return LocalModelRoutingDecision(
          current, task, LocalModelRoutingReason.keptFollowUp, 0);
    }

    // Heuristic scores are NOT benchmark quality measurements. Switching a
    // GGUF can cost many seconds of unload/load/prefill on Android. Require
    // clear benefit before paying that cost; block A→B→A oscillation for two
    // completed turns. Do not block a forced replacement of an unsafe model.
    final gain = score(best) - score(current);
    final minimumGain = (isAndroid ? 18 : 12) +
        (successfulTurnsSinceSwitch < 2 ? 18 : 0);
    if (gain < minimumGain) {
      return LocalModelRoutingDecision(
        current,
        task,
        successfulTurnsSinceSwitch < 2
            ? LocalModelRoutingReason.keptCooldown
            : LocalModelRoutingReason.keptInsufficientGain,
        gain,
      );
    }
    return LocalModelRoutingDecision(
        best, task, LocalModelRoutingReason.switchedForTask, gain);
  }

  LocalConversationTask classify(InferenceRequest request) {
    var prompt = request.prompt.trim().toLowerCase();
    // Follow-up turns such as "continua" inherit the immediately preceding
    // user topic, not the generated assistant answer.
    if (prompt.length < 32 && request.context.isNotEmpty) {
      for (final turn in request.context.reversed) {
        if (turn.role.name == 'user' && !turn.excludeFromContext) {
          prompt = '${turn.content.toLowerCase()} $prompt';
          break;
        }
      }
    }
    if (RegExp(
      r'\b(codice|code|coding|programma|programming|debug|bug|'
      r'flutter|dart|python|javascript|typescript|sql|'
      r'compila|compile|repository|funzione|function|script)\b',
      caseSensitive: false,
    ).hasMatch(prompt)) {
      return LocalConversationTask.coding;
    }
    if (RegExp(
      r'\b(perch[eéè]|why|pourquoi|analizza|analyze|analyse|'
      r'dimostra|prove|ragion|reason|logica|logic|'
      r'confronta|compare|calcola|calculate|matematica|math)\b',
      caseSensitive: false,
    ).hasMatch(prompt)) {
      return LocalConversationTask.reasoning;
    }
    return LocalConversationTask.general;
  }
}

enum LocalConversationTask { general, reasoning, coding }

enum LocalModelRoutingReason {
  initial,
  noEligible,
  memoryGuard,
  previousUnavailable,
  keptBest,
  keptFollowUp,
  keptCooldown,
  keptInsufficientGain,
  switchedForTask,
}

/// A decision is based only on installed model metadata and RAM telemetry.
class LocalModelRoutingDecision {
  const LocalModelRoutingDecision(
      this.model, this.task, this.reason, this.scoreGain);

  final AiModel? model;
  final LocalConversationTask task;
  final LocalModelRoutingReason reason;
  final int scoreGain;
}

/// Ephemeral, bounded state: never stores conversation text or model weights.
/// A route is recorded only AFTER a successful LOCAL completion, never when
/// it is merely selected, cancelled or fails before the first token.
class LocalSessionModelAffinity {
  LocalSessionModelAffinity({this.maxSessions = 24})
      : assert(maxSessions > 0);

  final int maxSessions;
  final Map<String, LocalSessionAffinitySnapshot> _sessions = {};

  LocalSessionAffinitySnapshot? get(String sessionId) =>
      _sessions[sessionId];

  void reset() => _sessions.clear();

  void recordSuccess(String sessionId, String modelId) {
    if (sessionId.isEmpty || modelId.isEmpty) return;
    final previous = _sessions.remove(sessionId);
    final switched = previous != null && previous.modelId != modelId;
    final turns = switched
        ? 0
        : previous == null
            ? 99
            : (previous.successfulTurnsSinceSwitch + 1).clamp(0, 99).toInt();
    if (_sessions.length >= maxSessions) {
      _sessions.remove(_sessions.keys.first);
    }
    _sessions[sessionId] = LocalSessionAffinitySnapshot(modelId, turns);
  }
}

class LocalSessionAffinitySnapshot {
  const LocalSessionAffinitySnapshot(
      this.modelId, this.successfulTurnsSinceSwitch);

  final String modelId;
  final int successfulTurnsSinceSwitch;
}
