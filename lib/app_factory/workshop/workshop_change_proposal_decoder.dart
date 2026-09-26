import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_structured_json.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';

/// Converts the Engineer model's structured response into a side-effect-free
/// [WorkshopChangeProposal].
///
/// This decoder never reads or writes the real workspace. It only validates
/// and normalizes the proposal so later review/validation layers can decide
/// whether it is safe to materialize in a VirtualWorkspace.
final class WorkshopChangeProposalDecoder {
  const WorkshopChangeProposalDecoder._();

  static WorkshopChangeProposal decode({
    required String requestId,
    required String responseText,
    Set<String> existingPaths = const <String>{},
  }) {
    final normalizedRequestId = requestId.trim();
    if (normalizedRequestId.isEmpty) {
      throw const FormatException('Workshop request id cannot be empty.');
    }

    final jsonText = WorkshopStructuredJson.extractObjectText(
      responseText,
      emptyMessage: 'Workshop implementation response cannot be empty.',
    );
    dynamic decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException {
      final repaired =
          WorkshopStructuredJson.repairMalformedContentStrings(jsonText);
      if (repaired == null) {
        rethrow;
      }
      decoded = jsonDecode(repaired);
    }

    if (decoded is! Map) {
      throw const FormatException(
        'Workshop proposal must be a JSON object.',
      );
    }

    final payload = Map<String, dynamic>.from(decoded);
    final summary = _optionalString(payload, 'summary');
    final analysis = _optionalString(payload, 'analysis');
    final explanation = _proposalExplanation(
      payload,
      summary: summary,
      analysis: analysis,
    );
    final validationNotes = _stringList(payload, 'validationNotes');
    final warnings = _stringList(payload, 'warnings');

    final rawChanges = payload['changes'];
    if (rawChanges is! List || rawChanges.isEmpty) {
      throw const FormatException(
        'Workshop proposal must contain at least one file change.',
      );
    }

    final changes = <WorkspaceFileChange>[];
    final seenPaths = <String>{};

    for (final rawChange in rawChanges) {
      if (rawChange is! Map) {
        throw const FormatException(
          'Each Workshop file change must be a JSON object.',
        );
      }

      final change = Map<String, dynamic>.from(rawChange);
      final path = _normalizeRelativePath(
        _requiredString(change, 'path'),
      );

      if (!seenPaths.add(path)) {
        throw FormatException(
          'Workshop proposal contains duplicate path: $path',
        );
      }

      final typeName = _normalizeChangeType(
        _requiredString(change, 'type').toLowerCase(),
        path: path,
        existingPaths: existingPaths,
      );
      switch (typeName) {
        case 'addition':
        case 'add':
        case 'create':
          changes.add(
            WorkspaceFileChange(
              path: path,
              type: WorkspaceChangeType.addition,
              afterContent: _requiredContent(change, path),
            ),
          );
          break;
        case 'modification':
        case 'modify':
        case 'update':
          changes.add(
            WorkspaceFileChange(
              path: path,
              type: WorkspaceChangeType.modification,
              afterContent: _requiredContent(change, path),
            ),
          );
          break;
        case 'deletion':
        case 'delete':
        case 'remove':
          changes.add(
            WorkspaceFileChange(
              path: path,
              type: WorkspaceChangeType.deletion,
            ),
          );
          break;
        default:
          throw FormatException(
            'Unsupported Workshop change type "$typeName" for $path.',
          );
      }
    }

    return WorkshopChangeProposal(
      requestId: normalizedRequestId,
      summary: summary,
      explanation: explanation,
      analysis: analysis,
      changes: List<WorkspaceFileChange>.unmodifiable(changes),
      validationNotes: validationNotes,
      warnings: warnings,
    );
  }

  static String _normalizeChangeType(
    String rawType, {
    required String path,
    required Set<String> existingPaths,
  }) {
    final normalized = rawType.trim().toLowerCase();
    switch (normalized) {
      case 'addition|modification':
      case 'modification|addition':
      case 'addition/modification':
      case 'modification/addition':
        return existingPaths.contains(path) ? 'modification' : 'addition';
      default:
        return normalized;
    }
  }

  static String _proposalExplanation(
    Map<String, dynamic> payload, {
    required String? summary,
    required String? analysis,
  }) {
    final value = payload['explanation'];
    if (value != null && value is! String) {
      throw const FormatException(
        'Workshop proposal field "explanation" must be text.',
      );
    }

    final explicit = value is String ? value.trim() : '';
    if (explicit.isNotEmpty) {
      return explicit;
    }

    // explanation is descriptive metadata, not an execution/safety gate.
    // Small local models occasionally omit this redundant field while still
    // returning a structurally valid, reviewable change set. Reuse existing
    // model-authored context instead of discarding the code or spending a
    // second inference. Reviewer, Validation and guarded apply remain intact.
    if (summary != null && summary.isNotEmpty) {
      return summary;
    }
    if (analysis != null && analysis.isNotEmpty) {
      return analysis;
    }

    throw const FormatException(
      'Workshop proposal field "explanation" is required.',
    );
  }

  static String _requiredString(
    Map<String, dynamic> payload,
    String key,
  ) {
    final value = payload[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Workshop proposal field "$key" is required.');
    }
    return value.trim();
  }

  static String? _optionalString(
    Map<String, dynamic> payload,
    String key,
  ) {
    final value = payload[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw FormatException('Workshop proposal field "$key" must be text.');
    }
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }

  static List<String> _stringList(
    Map<String, dynamic> payload,
    String key,
  ) {
    final value = payload[key];
    if (value == null) {
      return const <String>[];
    }
    if (value is! List || value.any((item) => item is! String)) {
      throw FormatException(
        'Workshop proposal field "$key" must be a list of strings.',
      );
    }

    return List<String>.unmodifiable(
      value
          .cast<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty),
    );
  }

  static String _requiredContent(
    Map<String, dynamic> change,
    String path,
  ) {
    final content = change['content'];
    if (content is! String) {
      throw FormatException(
        'Workshop change for $path requires string content.',
      );
    }
    return _normalizeOuterCodeFence(content);
  }

  static String _normalizeOuterCodeFence(String content) {
    final trimmed = content.trim();
    final lines = trimmed.split(RegExp(r'\r?\n'));
    if (lines.length < 3) {
      return content;
    }

    final first = lines.first.trim();
    final last = lines.last.trim();
    final fence = String.fromCharCodes(const <int>[96, 96, 96]);
    if (!first.startsWith(fence) || last != fence) {
      return content;
    }

    final language = first.substring(fence.length).trim();
    if (language.isNotEmpty &&
        RegExp(r'[^A-Za-z0-9_+.-]').hasMatch(language)) {
      return content;
    }

    // Only remove one fence that wraps the entire file content. Never remove
    // internal Markdown/code strings or attempt to repair arbitrary syntax.
    final body = lines.sublist(1, lines.length - 1).join('\n');
    return content.endsWith('\n') ? '$body\n' : body;
  }

  static String _normalizeRelativePath(String path) {
    var normalized = path.replaceAll('\\', '/').trim();

    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }

    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(normalized)) {
      throw FormatException(
        'Workshop change path must be workspace-relative: $path',
      );
    }

    final segments = normalized.split('/');
    if (segments.any(
      (segment) =>
          segment.isEmpty || segment == '.' || segment == '..',
    )) {
      throw FormatException(
        'Workshop change path is not safe: $path',
      );
    }

    return normalized;
  }
}
