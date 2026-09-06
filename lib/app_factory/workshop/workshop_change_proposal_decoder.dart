import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
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
  }) {
    final normalizedRequestId = requestId.trim();
    if (normalizedRequestId.isEmpty) {
      throw const FormatException('Workshop request id cannot be empty.');
    }

    final jsonText = _extractJson(responseText);
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map) {
      throw const FormatException(
        'Workshop proposal must be a JSON object.',
      );
    }

    final payload = Map<String, dynamic>.from(decoded);
    final explanation = _requiredString(payload, 'explanation');
    final summary = _optionalString(payload, 'summary');
    final analysis = _optionalString(payload, 'analysis');
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

      final typeName = _requiredString(change, 'type').toLowerCase();
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

  static String _extractJson(String responseText) {
    final normalized = responseText.trim();
    if (normalized.isEmpty) {
      throw const FormatException(
        'Workshop implementation response cannot be empty.',
      );
    }

    final fenced = RegExp(
      r'^```(?:json)?\s*([\s\S]*?)\s*```$',
      caseSensitive: false,
    ).firstMatch(normalized);

    return (fenced?.group(1) ?? normalized).trim();
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
    return content;
  }

  static String _normalizeRelativePath(String path) {
    final normalized = path.replaceAll('\\', '/').trim();
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
