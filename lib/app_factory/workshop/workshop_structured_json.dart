import 'dart:convert';

/// Extracts one JSON object from a Workshop model response without weakening
/// any downstream schema or safety validation.
///
/// Small local models can prepend/append a short natural-language sentence even
/// when instructed to return JSON only. This helper accepts:
/// - exact JSON objects;
/// - fenced JSON objects;
/// - one balanced top-level JSON object surrounded by prose.
///
/// It is string/escape aware, so braces inside generated code or JSON strings
/// do not terminate the object early.
abstract final class WorkshopStructuredJson {
  static String extractObjectText(
    String responseText, {
    required String emptyMessage,
  }) {
    final normalized = responseText.trim();
    if (normalized.isEmpty) {
      throw FormatException(emptyMessage);
    }

    final fenced = RegExp(
      r'```(?:json)?\s*([\s\S]*?)\s*```',
      caseSensitive: false,
    ).firstMatch(normalized);
    final fencedBody = fenced?.group(1)?.trim();
    if (fencedBody != null && fencedBody.isNotEmpty) {
      try {
        final decoded = jsonDecode(fencedBody);
        if (decoded is Map) {
          return fencedBody;
        }
      } on FormatException {
        // Keep going: Engineer code content can contain loose JSON escaping.
      }
    }

    try {
      final decoded = jsonDecode(normalized);
      if (decoded is Map) {
        return normalized;
      }
    } on FormatException {
      // Fall through to bounded-object recovery.
    }

    for (var start = normalized.indexOf('{');
        start >= 0;
        start = normalized.indexOf('{', start + 1)) {
      final candidate = _balancedObjectAt(normalized, start);
      if (candidate == null) {
        continue;
      }

      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map) {
          return candidate;
        }
      } on FormatException {
        // Keep scanning for a later complete object.
      }
    }

    return normalized;
  }


  /// Repairs only malformed JSON string escaping inside Engineer file-content
  /// values. Every other field remains strict JSON and is validated later by
  /// the normal Workshop proposal decoder.
  ///
  /// This exists for small local models that sometimes emit raw line breaks or
  /// unescaped double quotes inside a "content" value even while the surrounding
  /// proposal structure is otherwise valid.
  static String? repairMalformedContentStrings(String responseText) {
    final normalized = responseText.trim();
    if (normalized.isEmpty || normalized.length > 65536) {
      return null;
    }

    final firstBrace = normalized.indexOf('{');
    final lastBrace = normalized.lastIndexOf('}');
    if (firstBrace < 0 || lastBrace <= firstBrace) {
      return null;
    }

    final objectText = normalized.substring(firstBrace, lastBrace + 1);
    final budget = _WorkshopJsonRepairBudget(256);
    return _repairContentFields(
      objectText,
      searchStart: 0,
      depth: 0,
      budget: budget,
    );
  }

  static String? _repairContentFields(
    String text, {
    required int searchStart,
    required int depth,
    required _WorkshopJsonRepairBudget budget,
  }) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return text;
      }
    } on FormatException {
      // Continue with the narrowly-scoped content repair.
    }

    if (depth >= 8 || !budget.consume()) {
      return null;
    }

    final searchText = text.substring(searchStart);
    final match = RegExp(r'"content"\s*:\s*"').firstMatch(searchText);
    if (match == null) {
      return null;
    }

    final valueStart = searchStart + match.end;
    final candidateEnds = <int>[];

    for (var index = valueStart; index < text.length; index++) {
      if (text[index] != '"' || _isEscapedQuote(text, index)) {
        continue;
      }

      final next = _nextNonWhitespace(text, index + 1);
      if (next < 0 ||
          text[next] == '}' ||
          text[next] == ']' ||
          text[next] == ',') {
        candidateEnds.add(index);
      }
    }

    for (final valueEnd in candidateEnds) {
      if (!budget.consume()) {
        return null;
      }

      final escapedContent = _escapeLooseJsonString(
        text.substring(valueStart, valueEnd),
      );
      final candidate =
          '${text.substring(0, valueStart)}$escapedContent${text.substring(valueEnd)}';

      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map) {
          return candidate;
        }
      } on FormatException {
        // A later content field may need the same bounded repair.
      }

      final repaired = _repairContentFields(
        candidate,
        searchStart: valueStart + escapedContent.length + 1,
        depth: depth + 1,
        budget: budget,
      );
      if (repaired != null) {
        return repaired;
      }
    }

    return null;
  }

  static String _escapeLooseJsonString(String raw) {
    final buffer = StringBuffer();

    for (var index = 0; index < raw.length; index++) {
      final char = raw[index];
      final code = raw.codeUnitAt(index);

      if (char == '"') {
        buffer.write(r'\"');
        continue;
      }

      if (char == '\\') {
        if (index + 1 < raw.length) {
          final next = raw[index + 1];
          if ('"\\/bfnrt'.contains(next)) {
            buffer
              ..write('\\')
              ..write(next);
            index += 1;
            continue;
          }
          if (next == 'u' &&
              index + 5 < raw.length &&
              _isHex4(raw.substring(index + 2, index + 6))) {
            buffer.write(raw.substring(index, index + 6));
            index += 5;
            continue;
          }
        }

        buffer.write(r'\\');
        continue;
      }

      switch (code) {
        case 0x08:
          buffer.write(r'\b');
          break;
        case 0x09:
          buffer.write(r'\t');
          break;
        case 0x0A:
          buffer.write(r'\n');
          break;
        case 0x0C:
          buffer.write(r'\f');
          break;
        case 0x0D:
          buffer.write(r'\r');
          break;
        default:
          if (code < 0x20) {
            buffer.write(
              '\\u${code.toRadixString(16).padLeft(4, '0')}',
            );
          } else {
            buffer.write(char);
          }
      }
    }

    return buffer.toString();
  }

  static bool _isEscapedQuote(String text, int quoteIndex) {
    var backslashes = 0;
    for (var index = quoteIndex - 1;
        index >= 0 && text[index] == '\\';
        index--) {
      backslashes += 1;
    }
    return backslashes.isOdd;
  }

  static int _nextNonWhitespace(String text, int start) {
    for (var index = start; index < text.length; index++) {
      if (!RegExp(r'\s').hasMatch(text[index])) {
        return index;
      }
    }
    return -1;
  }

  static bool _isHex4(String value) =>
      RegExp(r'^[0-9A-Fa-f]{4}
    var depth = 0;
    var inString = false;
    var escaped = false;

    for (var index = start; index < text.length; index++) {
      final char = text[index];

      if (inString) {
        if (escaped) {
          escaped = false;
          continue;
        }
        if (char == r'\\') {
          escaped = true;
          continue;
        }
        if (char == '"') {
          inString = false;
        }
        continue;
      }

      if (char == '"') {
        inString = true;
        continue;
      }
      if (char == '{') {
        depth += 1;
        continue;
      }
      if (char == '}') {
        depth -= 1;
        if (depth == 0) {
          return text.substring(start, index + 1);
        }
        if (depth < 0) {
          return null;
        }
      }
    }

    return null;
  }
}
).hasMatch(value);

  static String? _balancedObjectAt(String text, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;

    for (var index = start; index < text.length; index++) {
      final char = text[index];

      if (inString) {
        if (escaped) {
          escaped = false;
          continue;
        }
        if (char == r'\\') {
          escaped = true;
          continue;
        }
        if (char == '"') {
          inString = false;
        }
        continue;
      }

      if (char == '"') {
        inString = true;
        continue;
      }
      if (char == '{') {
        depth += 1;
        continue;
      }
      if (char == '}') {
        depth -= 1;
        if (depth == 0) {
          return text.substring(start, index + 1);
        }
        if (depth < 0) {
          return null;
        }
      }
    }

    return null;
  }
}


final class _WorkshopJsonRepairBudget {
  _WorkshopJsonRepairBudget(this.remaining);

  int remaining;

  bool consume() {
    if (remaining <= 0) {
      return false;
    }
    remaining -= 1;
    return true;
  }
}
