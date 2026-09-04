import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';

/// Parses a structured response produced by the Workshop coding model
/// into a [WorkshopChangeProposal].
///
/// This class is deliberately side-effect free:
/// - it does not write files;
/// - it does not modify the workspace;
/// - it does not execute tools;
/// - it does not approve changes.
///
/// Its only responsibility is converting the machine-readable response
/// of the coding model into the existing Workshop change contract.
///
/// Expected JSON shape:
///
/// {
///   "summary": "...",
///   "explanation": "...",
///   "analysis": "...",
///   "validationNotes": ["..."],
///   "warnings": ["..."],
///   "changes": [
///     {
///       "path": "lib/main.dart",
///       "type": "addition",
///       "beforeContent": null,
///       "afterContent": "..."
///     }
///   ]
/// }
final class WorkshopChangeProposalParser {
  const WorkshopChangeProposalParser();

  /// Parses [response] into a [WorkshopChangeProposal].
  ///
  /// [requestId] identifies the Workshop request that produced the response.
  ///
  /// Throws [FormatException] when the response is not valid JSON or does
  /// not satisfy the required proposal contract.
  WorkshopChangeProposal parse({
    required String requestId,
    required String response,
  }) {
    final normalized = _extractJson(response);

    final dynamic decoded;

    try {
      decoded = jsonDecode(normalized);
    } on FormatException catch (error) {
      throw FormatException(
        'Workshop model response is not valid JSON: ${error.message}',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Workshop proposal must be a JSON object.',
      );
    }

    return _parseProposal(
      requestId: requestId,
      data: decoded,
    );
  }

  WorkshopChangeProposal _parseProposal({
    required String requestId,
    required Map<String, dynamic> data,
  }) {
    final explanation = _requiredString(
      data,
      'explanation',
    );

    final changesValue = data['changes'];

    if (changesValue is! List) {
      throw const FormatException(
        'Workshop proposal requires a "changes" array.',
      );
    }

    final changes = <WorkspaceFileChange>[];

    for (var index = 0; index < changesValue.length; index++) {
      final value = changesValue[index];

      if (value is! Map) {
        throw FormatException(
          'Workshop change at index $index must be an object.',
        );
      }

      changes.add(
        _parseChange(
          value: Map<String, dynamic>.from(value),
          index: index,
        ),
      );
    }

    return WorkshopChangeProposal(
      requestId: requestId,
      summary: _optionalString(data['summary']),
      explanation: explanation,
      analysis: _optionalString(data['analysis']),
      changes: List<WorkspaceFileChange>.unmodifiable(changes),
      validationNotes: _stringList(
        data['validationNotes'],
        fieldName: 'validationNotes',
      ),
      warnings: _stringList(
        data['warnings'],
        fieldName: 'warnings',
      ),
    );
  }

  WorkspaceFileChange _parseChange({
    required Map<String, dynamic> value,
    required int index,
  }) {
    final path = _requiredString(
      value,
      'path',
      context: 'change[$index]',
    );

    if (path.trim().isEmpty) {
      throw FormatException(
        'Workshop change at index $index has an empty path.',
      );
    }

    final typeValue = _requiredString(
      value,
      'type',
      context: 'change[$index]',
    );

    final type = _parseChangeType(
      typeValue,
      index: index,
    );

    final beforeContent = _nullableString(
      value['beforeContent'],
      fieldName: 'beforeContent',
      context: 'change[$index]',
    );

    final afterContent = _nullableString(
      value['afterContent'],
      fieldName: 'afterContent',
      context: 'change[$index]',
    );

    switch (type) {
      case WorkspaceChangeType.addition:
        if (afterContent == null) {
          throw FormatException(
            'Workshop addition at index $index requires '
            '"afterContent".',
          );
        }

        if (beforeContent != null) {
          throw FormatException(
            'Workshop addition at index $index must not contain '
            '"beforeContent".',
          );
        }

      case WorkspaceChangeType.modification:
        if (afterContent == null) {
          throw FormatException(
            'Workshop modification at index $index requires '
            '"afterContent".',
          );
        }

      case WorkspaceChangeType.deletion:
        if (beforeContent == null) {
          throw FormatException(
            'Workshop deletion at index $index requires '
            '"beforeContent".',
          );
        }

        if (afterContent != null) {
          throw FormatException(
            'Workshop deletion at index $index must not contain '
            '"afterContent".',
          );
        }
    }

    return WorkspaceFileChange(
      path: path,
      type: type,
      beforeContent: beforeContent,
      afterContent: afterContent,
    );
  }

  WorkspaceChangeType _parseChangeType(
    String value, {
    required int index,
  }) {
    switch (value.trim().toLowerCase()) {
      case 'addition':
      case 'add':
      case 'create':
        return WorkspaceChangeType.addition;

      case 'modification':
      case 'modify':
      case 'update':
        return WorkspaceChangeType.modification;

      case 'deletion':
      case 'delete':
      case 'remove':
        return WorkspaceChangeType.deletion;

      default:
        throw FormatException(
          'Unsupported Workshop change type "$value" '
          'at index $index.',
        );
    }
  }

  String _requiredString(
    Map<String, dynamic> data,
    String field, {
    String context = 'proposal',
  }) {
    final value = data[field];

    if (value is! String) {
      throw FormatException(
        'Workshop $context requires string field "$field".',
      );
    }

    if (value.trim().isEmpty) {
      throw FormatException(
        'Workshop $context field "$field" cannot be empty.',
      );
    }

    return value;
  }

  String? _optionalString(dynamic value) {
    if (value == null) {
      return null;
    }

    if (value is! String) {
      throw const FormatException(
        'Optional Workshop proposal text fields must be strings.',
      );
    }

    return value;
  }

  String? _nullableString(
    dynamic value, {
    required String fieldName,
    required String context,
  }) {
    if (value == null) {
      return null;
    }

    if (value is! String) {
      throw FormatException(
        'Workshop $context field "$fieldName" must be a string or null.',
      );
    }

    return value;
  }

  List<String> _stringList(
    dynamic value, {
    required String fieldName,
  }) {
    if (value == null) {
      return const <String>[];
    }

    if (value is! List) {
      throw FormatException(
        'Workshop proposal field "$fieldName" must be an array.',
      );
    }

    final result = <String>[];

    for (var index = 0; index < value.length; index++) {
      final item = value[index];

      if (item is! String) {
        throw FormatException(
          'Workshop proposal field "$fieldName" '
          'contains a non-string item at index $index.',
        );
      }

      result.add(item);
    }

    return List.unmodifiable(result);
  }

  /// Extracts the first JSON object from a model response.
  ///
  /// This permits the coding model to surround the structured payload
  /// with harmless Markdown such as ```json ... ```.
  ///
  /// The method deliberately does not attempt to interpret arbitrary
  /// natural-language text as a proposal.
  String _extractJson(String response) {
    final trimmed = response.trim();

    if (trimmed.isEmpty) {
      throw const FormatException(
        'Workshop model returned an empty response.',
      );
    }

    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      return trimmed;
    }

    final fencedStart = trimmed.indexOf('```');

    if (fencedStart >= 0) {
      final openingEnd = trimmed.indexOf('\n', fencedStart);

      if (openingEnd >= 0) {
        final closingStart = trimmed.indexOf(
          '```',
          openingEnd + 1,
        );

        if (closingStart > openingEnd) {
          final fencedContent = trimmed.substring(
            openingEnd + 1,
            closingStart,
          ).trim();

          if (fencedContent.startsWith('{') &&
              fencedContent.endsWith('}')) {
            return fencedContent;
          }
        }
      }
    }

    final jsonStart = trimmed.indexOf('{');
    final jsonEnd = trimmed.lastIndexOf('}');

    if (jsonStart >= 0 && jsonEnd > jsonStart) {
      return trimmed.substring(
        jsonStart,
        jsonEnd + 1,
      );
    }

    throw const FormatException(
      'Workshop model response does not contain a JSON proposal.',
    );
  }
}
