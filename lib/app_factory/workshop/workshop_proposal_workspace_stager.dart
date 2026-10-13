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
    final identifier = RegExp(r'^[A-Za-z_][A-Za-z_0-9]*$');
    if (!parts.every(identifier.hasMatch)) return false;

    // Flutter Android plugin/JVM classes use io.flutter.*, while the
    // legitimate Dart MethodChannel API is package:flutter/services.dart.
    if (parts.length >= 3 && parts[0] == 'io' && parts[1] == 'flutter') {
      return true;
    }
    return parts.length >= 2 &&
        const <String>[
          'com', 'org', 'android', 'androidx', 'java', 'javax', 'kotlin',
        ].contains(parts.first);
  }

  static Iterable<String> _dartImportUris(String source) sync* {
    var offset = source.startsWith('\uFEFF') ? 1 : 0;
    var statementStart = true;
    var braceDepth = 0;
    var inImportDirective = false;
    // Dart permits a Unix script tag before directives. Treat it as trivia
    // rather than turning off the import-directive state until the next ';'.
    if (source.startsWith('#!', offset)) {
      while (offset < source.length &&
          source[offset] != '\n' &&
          source[offset] != '\r') {
        offset++;
      }
    }
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
        if (inImportDirective && braceDepth == 0) {
          // Dart accepts adjacent URI string segments: concatenate all of
          // them before checking the JVM namespace, including raw/triple.
          final first = _readDartImportUri(source, offset);
          if (first != null) {
            var uri = first;
            var cursor = _skipDartUriLiteral(source, offset);
            while (cursor < source.length) {
              final nextSegment = _skipDartTrivia(source, cursor);
              final part = _readDartImportUri(source, nextSegment);
              if (part == null) break;
              uri += part;
              cursor = _skipDartUriLiteral(source, nextSegment);
            }
            yield uri;
            offset = cursor;
            statementStart = false;
            continue;
          }
        }
        offset = _skipDartString(
          source,
          rawString ? offset + 1 : offset,
          raw: rawString,
        );
        statementStart = false;
        continue;
      }
      // Conditional import test strings are not imported URIs. Ignore the
      // entire balanced parenthetical condition; only its following URI
      // operand (and the leading URI) is eligible for native-class checks.
      if (inImportDirective && braceDepth == 0 && char == '(') {
        offset = _skipDartImportCondition(source, offset);
        statementStart = false;
        continue;
      }
      if (braceDepth == 0 && statementStart && char == '@') {
        final afterMetadata = _skipDartDirectiveMetadata(source, offset);
        if (afterMetadata > offset) {
          offset = afterMetadata;
          continue; // Metadata precedes a directive; preserve eligibility.
        }
      }
      if (braceDepth == 0 &&
          statementStart &&
          source.startsWith('import', offset) &&
          (offset + 6 == source.length ||
              !_isDartIdentifierChar(source[offset + 6]))) {
        inImportDirective = true;
      }
      if (char == '{') {
        braceDepth++;
      } else if (char == '}' && braceDepth > 0) {
        braceDepth--;
      } else if (char == ';' && braceDepth == 0) {
        statementStart = true;
        inImportDirective = false;
        offset++;
        continue;
      }
      statementStart = false;
      offset++;
    }
  }

  static int _skipDartDirectiveMetadata(String source, int offset) {
    var index = offset + 1;
    if (index >= source.length ||
        !_isDartIdentifierChar(source[index])) {
      return offset;
    }
    // Read the annotation identifier (including qualified constructor names).
    while (index < source.length &&
        (_isDartIdentifierChar(source[index]) || source[index] == '.')) {
      index++;
    }
    index = _skipDartTrivia(source, index);
    if (index >= source.length || source[index] != '(') return index;
    var depth = 1;
    index++;
    while (index < source.length && depth > 0) {
      final char = source[index];
      final next = index + 1 < source.length ? source[index + 1] : '';
      if (char == '/' && next == '/') {
        index += 2;
        while (index < source.length &&
            source[index] != '\r' &&
            source[index] != '\n') {
          index++;
        }
        continue;
      }
      if (char == '/' && next == '*') {
        index = _skipDartBlockComment(source, index);
        continue;
      }
      final rawString = (char == 'r' || char == 'R') &&
          (next == "'" || next == '"');
      if (char == "'" || char == '"' || rawString) {
        index = _skipDartString(
          source,
          rawString ? index + 1 : index,
          raw: rawString,
        );
        continue;
      }
      if (char == '(') {
        depth++;
      } else if (char == ')') {
        depth--;
      }
      index++;
    }
    return _skipDartTrivia(source, index);
  }

  static int _skipDartUriLiteral(String source, int offset) {
    final raw = (source[offset] == 'r' || source[offset] == 'R') &&
        offset + 1 < source.length &&
        (source[offset + 1] == "'" || source[offset + 1] == '"');
    return _skipDartString(
      source,
      raw ? offset + 1 : offset,
      raw: raw,
    );
  }

  static int _skipDartImportCondition(String source, int offset) {
    var nesting = 1;
    offset++;
    while (offset < source.length && nesting > 0) {
      final char = source[offset];
      final next = offset + 1 < source.length ? source[offset + 1] : '';
      if (char == '/' && next == '/') {
        offset += 2;
        while (offset < source.length &&
            source[offset] != '\n' && source[offset] != '\r') {
          offset++;
        }
        continue;
      }
      if (char == '/' && next == '*') {
        offset = _skipDartBlockComment(source, offset);
        continue;
      }
      final raw = (char == 'r' || char == 'R') &&
          (next == "'" || next == '"');
      if (char == "'" || char == '"' || raw) {
        offset = _skipDartString(source, raw ? offset + 1 : offset, raw: raw);
        continue;
      }
      if (char == '(') {
        nesting++;
      } else if (char == ')') {
        nesting--;
      }
      offset++;
    }
    return offset;
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
      if (!raw && source.codeUnitAt(index) == 92) {
        index += 2;
        continue;
      }
      if (!raw &&
          source.codeUnitAt(index) == 36 &&
          index + 1 < source.length &&
          source[index + 1] == '{') {
        // Nested interpolation expressions can contain same-quote strings,
        // semicolons, comments, braces and further interpolations.
        index = _skipDartInterpolation(source, index + 2);
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

  static int _skipDartInterpolation(String source, int index) {
    var depth = 1;
    while (index < source.length) {
      final char = source[index];
      final next = index + 1 < source.length ? source[index + 1] : '';
      if (char == '/' && next == '/') {
        index += 2;
        while (index < source.length &&
            source[index] != '\n' &&
            source[index] != '\r') {
          index++;
        }
        continue;
      }
      if (char == '/' && next == '*') {
        index = _skipDartBlockComment(source, index);
        continue;
      }
      final rawString = (char == 'r' || char == 'R') &&
          (next == "'" || next == '"');
      if (char == "'" || char == '"' || rawString) {
        index = _skipDartString(
          source,
          rawString ? index + 1 : index,
          raw: rawString,
        );
        continue;
      }
      if (char == '{') {
        depth++;
      } else if (char == '}' && --depth == 0) {
        return index + 1;
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
    // Dart import URIs may also use raw/triple-quoted literals. Strip the
    // actual width of both delimiters before validating the native URI.
    final triple = index + 2 < source.length &&
        source[index + 1] == quote &&
        source[index + 2] == quote;
    final delimiterWidth = triple ? 3 : 1;
    if (end - index < 2 * delimiterWidth) return null;
    // Escaped URIs are not canonical JVM dotted names; they remain outside
    // this narrow guard and must still pass the mandatory review/validator.
    return source.substring(
      index + delimiterWidth,
      end - delimiterWidth,
    );
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
