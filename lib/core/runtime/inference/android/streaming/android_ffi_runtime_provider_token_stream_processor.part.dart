/// Token stream processing for Android FFI runtime output.
///
/// Handles structural template sanitization, buffering, and first-token
/// transition bookkeeping without changing the runtime stream behavior.
part of '../../runtime_core.dart';


class _AndroidFfiTokenStreamProcessor {
  _AndroidFfiTokenStreamProcessor(this._owner);

  final AndroidFfiRuntimeProvider _owner;
  String _pendingStructuralTemplateOutput = '';

  static const List<String> _structuralTemplateTokens = <String>[
    '<|start_header_id|>assistant<|end_header_id|>',
    '&lt;|start_header_id|&gt;assistant&lt;|end_header_id|&gt;',
    '&amp;lt;|start_header_id|&gt;assistant&amp;lt;|end_header_id|&gt;',
    '<|start_header_id|>user<|end_header_id|>',
    '&lt;|start_header_id|&gt;user&lt;|end_header_id|&gt;',
    '&amp;lt;|start_header_id|&gt;user&amp;lt;|end_header_id|&gt;',
    '<|start_header_id|>system<|end_header_id|>',
    '&lt;|start_header_id|&gt;system&lt;|end_header_id|&gt;',
    '&amp;lt;|start_header_id|&gt;system&amp;lt;|end_header_id|&gt;',
    '<|eot_id|>',
    '&lt;|eot_id|&gt;',
    '&amp;lt;|eot_id|&gt;',
    '<|start_header_id|>',
    '&lt;|start_header_id|&gt;',
    '&amp;lt;|start_header_id|&gt;',
    '<|end_header_id|>',
    '&lt;|end_header_id|&gt;',
    '&amp;lt;|end_header_id|&gt;',
    '<|im_start|>',
    '&lt;|im_start|&gt;',
    '&amp;lt;|im_start|&gt;',
    '<|im_end|>',
    '&lt;|im_end|&gt;',
    '&amp;lt;|im_end|&gt;',
    '<think>',
    '</think>',
    '&lt;think&gt;',
    '&lt;/think&gt;',
    '<|endoftext|>',
    '<|EOT|>',
    '<|pinned_banner|>',
  ];

  static final Map<int, List<String>> _structuralTemplateTokensByLeadingCodeUnit =
      _buildStructuralTemplateTokensByLeadingCodeUnit();
  static final RegExp _controlCharPattern = RegExp(r'[\r\u0000]');

  String sanitizeStructuralTemplateOutput(String input) {
    if (input.isEmpty && _pendingStructuralTemplateOutput.isEmpty) {
      return '';
    }

    final combined = '$_pendingStructuralTemplateOutput$input'
        .replaceAll(_controlCharPattern, '');
    _pendingStructuralTemplateOutput = '';
    if (combined.isEmpty) {
      return '';
    }

    final output = StringBuffer();
    var index = 0;
    while (index < combined.length) {
      final matchedToken = _matchStructuralTemplateToken(combined, index);
      if (matchedToken != null) {
        index += matchedToken.length;
        continue;
      }

      final pendingTail = _pendingStructuralTemplateTail(combined, index);
      if (pendingTail != null) {
        _pendingStructuralTemplateOutput = pendingTail;
        break;
      }

      output.writeCharCode(combined.codeUnitAt(index));
      index++;
    }

    return output.toString();
  }

  String flushStructuralTemplateOutput() {
    if (_pendingStructuralTemplateOutput.isEmpty) {
      return '';
    }

    final pending = _pendingStructuralTemplateOutput;
    _pendingStructuralTemplateOutput = '';
    return pending;
  }

  void discardStructuralTemplateOutput() {
    _pendingStructuralTemplateOutput = '';
  }

  bool isNoiseToken(String piece) {
    return piece.isEmpty || AndroidFfiRuntimeProvider._systemSanityTags.contains(piece);
  }

  DateTime? handleFirstTokenIfNeeded(String piece) {
    if (!_owner._preFirstTokenActive) {
      return null;
    }
    _owner._preFirstTokenActive = false;
    _owner._setPhase(RuntimePhase.streaming);
    final now = DateTime.now();
    _log(
      '[FIRST_TOKEN_PHASE] phase=${_owner._runtimePhase.name} chars=${piece.length} ts=${now.microsecondsSinceEpoch}',
    );
    return now;
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }

  String? _matchStructuralTemplateToken(String text, int index) {
    final candidates = _structuralTemplateTokensByLeadingCodeUnit[text.codeUnitAt(index)] ??
        _structuralTemplateTokens;
    for (final token in candidates) {
      if (text.startsWith(token, index)) {
        return token;
      }
    }
    return null;
  }

  String? _pendingStructuralTemplateTail(String text, int index) {
    final remaining = text.substring(index);
    final candidates = _structuralTemplateTokensByLeadingCodeUnit[remaining.codeUnitAt(0)] ??
        _structuralTemplateTokens;
    for (final token in candidates) {
      if (remaining.length < token.length && token.startsWith(remaining)) {
        return remaining;
      }
    }
    return null;
  }

  static Map<int, List<String>> _buildStructuralTemplateTokensByLeadingCodeUnit() {
    final groupedTokens = <int, List<String>>{};
    for (final token in _structuralTemplateTokens) {
      final leadingCodeUnit = token.codeUnitAt(0);
      groupedTokens.putIfAbsent(leadingCodeUnit, () => <String>[]).add(token);
    }
    return groupedTokens;
  }
}
