import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal_decoder.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_workspace_proposal_applier.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

/// Bridges an Engineer response into the existing VirtualWorkspace pipeline.
///
/// This boundary deliberately performs only three operations:
/// 1. decode the structured Engineer response into a WorkshopChangeProposal;
/// 2. materialize that proposal inside the active WorkspaceSession;
/// 3. move the session to review once the virtual changes are staged.
///
/// It never approves or applies changes to the real repository. Reviewer,
/// validation and explicit approval remain mandatory later stages.
final class WorkshopProposalWorkspaceStager {
  const WorkshopProposalWorkspaceStager({
    WorkshopWorkspaceProposalApplier applier =
        const WorkshopWorkspaceProposalApplier(),
  }) : _applier = applier;

  final WorkshopWorkspaceProposalApplier _applier;

  WorkshopChangeProposal stage({
    required WorkspaceSession session,
    required String responseText,
  }) {
    final proposal = WorkshopChangeProposalDecoder.decode(
      requestId: session.context.request.id,
      responseText: responseText,
      existingPaths: session.workspace.paths.toSet(),
    );

    _validateTaskScope(
      session: session,
      proposal: proposal,
    );
    _validateDartNativeImports(proposal);

    final alreadyHasStagedChanges = session.hasChanges;
    if (proposal.isNotEmpty &&
        !alreadyHasStagedChanges &&
        !_materializesWorkspaceChange(
          session: session,
          proposal: proposal,
        )) {
      throw const FormatException(
        'Workshop proposal produced no staged workspace changes.',
      );
    }

    _applier.applyProposal(
      session: session,
      proposal: proposal,
    );

    if (proposal.isNotEmpty) {
      session.beginReview();
    }

    return proposal;
  }

  // Token-aware, bounded lexical scan: reject only actual Dart import
  // directives, not import-looking content within strings and comments.
  // This is not a compiler; other source correctness remains Reviewer/Validation
  // responsibility. It does not inspect or reject Kotlin/XML bridge files.
  static void _validateDartNativeImports(WorkshopChangeProposal proposal) {
    for (final change in proposal.changes) {
      if (change.isDeletion || !change.path.toLowerCase().endsWith('.dart')) {
        continue;
      }
      final source = change.afterContent;
      if (source == null) continue;
      for (final uri in _dartImportUris(source)) {
        if (!_isJVMClassUri(uri)) continue;
        throw FormatException(
          'Workshop Dart source imports an Android/JVM class directly. '
          'Implement UI in Flutter/Dart or declare a matching platform channel.',
          change.path,
        );
      }
    }
  }

  static bool _isJVMClassUri(String uri) {
    if (uri.endsWith('.dart') || uri.contains(':') || uri.contains('/')) {
      return false; // Normal Dart file, dart:/package:, or relative URI.
    }
    final parts = uri.split('.');
    if (parts.length < 3 ||
        !const <String>[
          'com', 'org', 'android', 'androidx', 'java', 'javax', 'kotlin',
        ].contains(parts.first)) {
      return false;
    }
    final identifier = RegExp(r'^[A-Za-z_][A-Za-z_0-9]*$');
    return parts.every(identifier.hasMatch);
  }

  static Iterable<String> _dartImportUris(String source) sync* {
    var offset = 0;
    var statementStart = true;
    var braceDepth = 0;
    while (offset < source.length) {
      final char = source[offset];
      final next = offset + 1 < source.length ? source[offset + 1] : '';
      if (_isDartSpace(char)) {
        offset++;
        continue;
      }
      if (char == '/' && next == '/') {
        offset += 2;
        while (offset < source.length &&
            source[offset] != '\n' &&
            source[offset] != '\r') {
          offset++;
        }
        continue;
      }
      if (char == '/' && next == '*') {
        offset = _skipDartBlockComment(source, offset);
        continue;
      }
      final rawString = (char == 'r' || char == 'R') &&
          (next == "'" || next == '"');
      if (char == "'" || char == '"' || rawString) {
        offset = _skipDartString(
          source,
          rawString ? offset + 1 : offset,
          raw: rawString,
        );
        statementStart = false;
        continue;
      }
      if (braceDepth == 0 &&
          statementStart &&
          source.startsWith('import', offset) &&
          (offset + 6 == source.length ||
              !_isDartIdentifierChar(source[offset + 6]))) {
        final valueStart = _skipDartTrivia(source, offset + 6);
        final uri = _readDartImportUri(source, valueStart);
        if (uri != null) yield uri;
      }
      if (char == '{') {
        braceDepth++;
      } else if (char == '}' && braceDepth > 0) {
        braceDepth--;
      } else if (char == ';' && braceDepth == 0) {
        statementStart = true;
        offset++;
        continue;
      }
      statementStart = false;
      offset++;
    }
  }

  static bool _isDartSpace(String c) =>
      c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\uFEFF';

  static bool _isDartIdentifierChar(String c) {
    if (c.isEmpty) return false;
    final n = c.codeUnitAt(0);
    return (n >= 65 && n <= 90) ||
        (n >= 97 && n <= 122) ||
        (n >= 48 && n <= 57) ||
        c == '_' ||
        c == r'$';
  }

  static int _skipDartTrivia(String source, int offset) {
    while (offset < source.length) {
      final char = source[offset];
      final next = offset + 1 < source.length ? source[offset + 1] : '';
      if (_isDartSpace(char)) {
        offset++;
      } else if (char == '/' && next == '/') {
        offset += 2;
        while (offset < source.length &&
            source[offset] != '\n' &&
            source[offset] != '\r') {
          offset++;
        }
      } else if (char == '/' && next == '*') {
        offset = _skipDartBlockComment(source, offset);
      } else {
        break;
      }
    }
    return offset;
  }

  static int _skipDartBlockComment(String source, int offset) {
    var nesting = 1;
    offset += 2;
    while (offset < source.length && nesting > 0) {
      final next = offset + 1 < source.length ? source[offset + 1] : '';
      if (source[offset] == '/' && next == '*') {
        nesting++;
        offset += 2;
      } else if (source[offset] == '*' && next == '/') {
        nesting--;
        offset += 2;
      } else {
        offset++;
      }
    }
    return offset;
  }

  static int _skipDartString(
    String source,
    int quoteIndex, {
    required bool raw,
  }) {
    final quote = source[quoteIndex];
    final triple = quoteIndex + 2 < source.length &&
        source[quoteIndex + 1] == quote &&
        source[quoteIndex + 2] == quote;
    var index = quoteIndex + (triple ? 3 : 1);
    while (index < source.length) {
      if (!raw && source[index] == r'\') {
        index += 2;
        continue;
      }
      if (source[index] == quote) {
        if (!triple) return index + 1;
        if (index + 2 < source.length &&
            source[index + 1] == quote &&
            source[index + 2] == quote) {
          return index + 3;
        }
      }
      index++;
    }
    return source.length;
  }

  static String? _readDartImportUri(String source, int index) {
    if (index >= source.length) return null;
    var raw = false;
    if ((source[index] == 'r' || source[index] == 'R') &&
        index + 1 < source.length &&
        (source[index + 1] == "'" || source[index + 1] == '"')) {
      raw = true;
      index++;
    }
    if (source[index] != "'" && source[index] != '"') return null;
    final quote = source[index];
    final end = _skipDartString(source, index, raw: raw);
    if (end <= index + 1 || end > source.length ||
        source[end - 1] != quote) {
      return null;
    }
    // Import URIs are normal single-quoted/double-quoted string literals.
    // An escaped URI is not a canonical JVM dotted class name, so no match.
    return source.substring(index + 1, end - 1);
  }

  static bool _materializesWorkspaceChange({
    required WorkspaceSession session,
    required WorkshopChangeProposal proposal,
  }) {
    for (final change in proposal.changes) {
      final path = change.path.trim();
      if (change.isDeletion) {
        if (session.workspace.contains(path)) {
          return true;
        }
        continue;
      }

      if (change.isAddition || change.isModification) {
        final next = change.afterContent;
        if (next != null && session.workspace.read(path) != next) {
          return true;
        }
      }
    }
    return false;
  }

  static void _validateTaskScope({
    required WorkspaceSession session,
    required WorkshopChangeProposal proposal,
  }) {
    final request = session.context.request;
    final targetFiles = request.targetFiles
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();

    if (targetFiles.isNotEmpty) {
      for (final change in proposal.changes) {
        final path = change.path.trim();
        if (!targetFiles.contains(path)) {
          throw FormatException(
            'Workshop proposal path "$path" is outside the current '
            'task targetFiles.',
          );
        }
      }
    }

    if (request.operation == WorkshopOperation.create &&
        targetFiles.contains('lib/main.dart') &&
        !session.workspace.contains('lib/main.dart')) {
      final materializesEntryPoint = proposal.changes.any(
        (change) =>
            change.path.trim() == 'lib/main.dart' && !change.isDeletion,
      );
      if (!materializesEntryPoint) {
        throw const FormatException(
          'Workshop create proposal must materialize required target '
          '"lib/main.dart".',
        );
      }
    }
  }
}
