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
      final decoded = jsonDecode(fencedBody);
      if (decoded is Map) {
        return fencedBody;
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
