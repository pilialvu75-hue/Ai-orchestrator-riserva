/// Token stream processing for Android FFI runtime output.
///
/// Handles structural template sanitization, reasoning-block suppression,
/// buffering, and first-token transition bookkeeping without changing the
/// runtime stream behavior.
part of '../../runtime_core.dart';

class _AndroidFfiTokenStreamProcessor {
  _AndroidFfiTokenStreamProcessor(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  String _pendingStructuralTemplateOutput = '';

  // ---------------------------------------------------------------------------
  // Reasoning / <think> state
  // ---------------------------------------------------------------------------
  //
  // Some instruct/reasoning models emit:
  //
  //   <think>
  //   internal reasoning...
  //   </think>
  //   final answer
  //
  // The reasoning must never be rendered as user-visible answer text.
  //
  // This is intentionally model-agnostic. We do not hardcode "DeepSeek" here:
  // any supported model using the same reasoning markers gets identical
  // stream semantics.
  bool _insideReasoningBlock = false;
  String _pendingReasoningMarker = '';

  static const List<String> _reasoningStartTokens = <String>[
    '<think>',
    '&lt;think&gt;',
    '&amp;lt;think&amp;gt;',
  ];

  static const List<String> _reasoningEndTokens = <String>[
    '</think>',
    '&lt;/think&gt;',
    '&amp;lt;/think&amp;gt;',
  ];

  static const List<String> _structuralTemplateTokens = <String>[
    // Llama 3 / ChatML
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

    // Qwen / ChatML
    '<|im_start|>',
    '&lt;|im_start|&gt;',
    '&amp;lt;|im_start|&gt;',
    '<|im_end|>',
    '&lt;|im_end|&gt;',
    '&amp;lt;|im_end|&gt;',
    '<|user|>',
    '&lt;|user|&gt;',
    '&amp;lt;|user|&gt;',
    '<|assistant|>',
    '&lt;|assistant|&gt;',
    '&amp;lt;|assistant|&gt;',
    '<|system|>',
    '&lt;|system|&gt;',
    '&amp;lt;|system|&gt;',
    '<|end|>',
    '&lt;|end|&gt;',
    '&amp;lt;|end|&gt;',

    // Zephyr / generic
    '</s>',
    '&lt;/s&gt;',
    '&amp;lt;/s&gt;',

    // DeepSeek-R1 / DeepSeek-R1-Distill
    '<｜begin▁of▁sentence｜>',
    '<｜User｜>',
    '<｜Assistant｜>',
    '<｜end▁of▁sentence｜>',

    // Reasoning markers
    '<think>',
    '</think>',
    '&lt;think&gt;',
    '&lt;/think&gt;',
    '&amp;lt;think&amp;gt;',
    '&amp;lt;/think&amp;gt;',

    // Other structural/sanity markers already supported
    '<|endoftext|>',
    '<|EOT|>',
    '<|pinned_banner|>',
  ];

  static final Map<int, List<String>>
      _structuralTemplateTokensByLeadingCodeUnit =
      _buildStructuralTemplateTokensByLeadingCodeUnit();

  static final RegExp _controlCharPattern =
      RegExp(r'[\r\u0000]');

  // ---------------------------------------------------------------------------
  // Public stream sanitization
  // ---------------------------------------------------------------------------

  String sanitizeStructuralTemplateOutput(String input) {
    if (input.isEmpty &&
        _pendingStructuralTemplateOutput.isEmpty &&
        _pendingReasoningMarker.isEmpty) {
      return '';
    }

    final combined = '$_pendingStructuralTemplateOutput'
            '$_pendingReasoningMarker'
            '$input'
        .replaceAll(_controlCharPattern, '');

    _pendingStructuralTemplateOutput = '';
    _pendingReasoningMarker = '';

    if (combined.isEmpty) {
      return '';
    }

    final output = StringBuffer();
    var index = 0;

    while (index < combined.length) {
      // -----------------------------------------------------------------------
      // Reasoning start/end markers are handled before generic structural
      // sanitization so that the content between them can be suppressed.
      // -----------------------------------------------------------------------
      final reasoningStart = _matchReasoningToken(
        combined,
        index,
        _reasoningStartTokens,
      );

      if (reasoningStart != null) {
        _insideReasoningBlock = true;
        index += reasoningStart.length;
        continue;
      }

      final reasoningEnd = _matchReasoningToken(
        combined,
        index,
        _reasoningEndTokens,
      );

      if (reasoningEnd != null) {
        _insideReasoningBlock = false;
        index += reasoningEnd.length;
        continue;
      }

      // -----------------------------------------------------------------------
      // Inside <think>...</think>:
      //
      // Suppress all reasoning characters. We still scan for a closing marker
      // so the visible response can resume immediately after </think>.
      // -----------------------------------------------------------------------
      if (_insideReasoningBlock) {
        final pendingTail =
            _pendingReasoningStructuralTail(combined, index);

        if (pendingTail != null) {
          _pendingReasoningMarker = pendingTail;
          break;
        }

        index++;
        continue;
      }

      // -----------------------------------------------------------------------
      // Generic structural/template token suppression.
      // -----------------------------------------------------------------------
      final matchedToken =
          _matchStructuralTemplateToken(combined, index);

      if (matchedToken != null) {
        index += matchedToken.length;
        continue;
      }

      // -----------------------------------------------------------------------
      // A chunk can end in the middle of a structural marker.
      //
      // Preserve only a possible structural suffix and wait for the next
      // incoming chunk before rendering anything.
      // -----------------------------------------------------------------------
      final pendingTail =
          _pendingStructuralTemplateTail(combined, index);

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
    // If a reasoning block is still open, there is no safe visible output to
    // flush from the pending marker. Keep it suppressed.
    if (_insideReasoningBlock) {
      _pendingStructuralTemplateOutput = '';
      _pendingReasoningMarker = '';
      return '';
    }

    if (_pendingStructuralTemplateOutput.isEmpty &&
        _pendingReasoningMarker.isEmpty) {
      return '';
    }

    final pending =
        '$_pendingStructuralTemplateOutput$_pendingReasoningMarker';

    _pendingStructuralTemplateOutput = '';
    _pendingReasoningMarker = '';

    if (_structuralTemplateTokens.any(
      (token) => token.startsWith(pending),
    )) {
      return '';
    }

    if (_reasoningStartTokens.any(
      (token) => token.startsWith(pending),
    )) {
      return '';
    }

    if (_reasoningEndTokens.any(
      (token) => token.startsWith(pending),
    )) {
      return '';
    }

    return pending;
  }

  void discardStructuralTemplateOutput() {
    _pendingStructuralTemplateOutput = '';
    _pendingReasoningMarker = '';
    _insideReasoningBlock = false;
  }

  bool isNoiseToken(String piece) {
    if (piece.isEmpty) {
      return true;
    }

    if (AndroidFfiRuntimeProvider._systemSanityTags.contains(piece)) {
      return true;
    }

    if (_isReasoningMarker(piece)) {
      return true;
    }

    // While inside a reasoning block every generated piece is internal
    // reasoning and therefore not user-visible.
    if (_insideReasoningBlock) {
      return true;
    }

    return false;
  }

  DateTime? handleFirstTokenIfNeeded(String piece) {
    if (!_owner._preFirstTokenActive) {
      return null;
    }

    _owner._preFirstTokenActive = false;
    _owner._setPhase(RuntimePhase.streaming);

    final now = DateTime.now();

    _log(
      '[FIRST_TOKEN_PHASE] '
      'phase=${_owner._runtimePhase.name} '
      'chars=${piece.length} '
      'ts=${now.microsecondsSinceEpoch}',
    );

    return now;
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }

  // ---------------------------------------------------------------------------
  // Reasoning helpers
  // ---------------------------------------------------------------------------

  String? _matchReasoningToken(
    String text,
    int index,
    List<String> tokens,
  ) {
    final candidates =
        tokens.where((token) => token.codeUnitAt(0) == text.codeUnitAt(index));

    for (final token in candidates) {
      if (text.startsWith(token, index)) {
        return token;
      }
    }

    return null;
  }

  String? _pendingReasoningStructuralTail(
    String text,
    int index,
  ) {
    final remaining = text.substring(index);

    if (remaining.isEmpty) {
      return null;
    }

    final candidates = <String>[
      ..._reasoningStartTokens,
      ..._reasoningEndTokens,
    ];

    for (final token in candidates) {
      if (remaining.length < token.length &&
          token.startsWith(remaining)) {
        return remaining;
      }
    }

    return null;
  }

  bool _isReasoningMarker(String piece) {
    return _reasoningStartTokens.contains(piece) ||
        _reasoningEndTokens.contains(piece);
  }

  // ---------------------------------------------------------------------------
  // Generic structural-template helpers
  // ---------------------------------------------------------------------------

  String? _matchStructuralTemplateToken(
    String text,
    int index,
  ) {
    final candidates =
        _structuralTemplateTokensByLeadingCodeUnit[
                text.codeUnitAt(index)] ??
            _structuralTemplateTokens;

    for (final token in candidates) {
      if (text.startsWith(token, index)) {
        return token;
      }
    }

    return null;
  }

  String? _pendingStructuralTemplateTail(
    String text,
    int index,
  ) {
    final remaining = text.substring(index);

    if (remaining.isEmpty) {
      return null;
    }

    final candidates =
        _structuralTemplateTokensByLeadingCodeUnit[
                remaining.codeUnitAt(0)] ??
            _structuralTemplateTokens;

    for (final token in candidates) {
      if (remaining.length < token.length &&
          token.startsWith(remaining)) {
        return remaining;
      }
    }

    return null;
  }

  static Map<int, List<String>>
      _buildStructuralTemplateTokensByLeadingCodeUnit() {
    final groupedTokens = <int, List<String>>{};

    for (final token in _structuralTemplateTokens) {
      final leadingCodeUnit = token.codeUnitAt(0);

      groupedTokens
          .putIfAbsent(
            leadingCodeUnit,
            () => <String>[],
          )
          .add(token);
    }

    return groupedTokens;
  }
}
