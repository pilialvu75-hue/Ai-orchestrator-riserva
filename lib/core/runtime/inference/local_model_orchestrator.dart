import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';

/// Selects only already-installed, validated and runtime-compatible GGUFs.
///
/// This is a per-turn local routing decision: no prompt rewriting, cloud
/// access, model downloads, or mutation of the user's manual selection.
class LocalModelOrchestrator {
  const LocalModelOrchestrator();

  AiModel? select({
    required InferenceRequest request,
    required Iterable<AiModel> availableModels,
    required AiModel? preferredModel,
    required bool Function(AiModel) supportsModel,
    ResourceSample? resources,
    bool isAndroid = false,
  }) {
    final eligible = availableModels.where((model) =>
        model.isDownloaded &&
        model.validationStatus == ModelValidationStatus.validatedOk &&
        (model.localPath?.trim().isNotEmpty ?? false) &&
        supportsModel(model)).toList(growable: false);
    if (eligible.isEmpty) return null;

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
    if (safe.isEmpty) return null;

    final task = classify(request);
    final preferredId = preferredModel?.id;
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
    return safe.first;
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
