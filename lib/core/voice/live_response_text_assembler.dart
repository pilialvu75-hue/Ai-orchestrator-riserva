/// Merges streaming inference tokens into one Live answer.
///
/// InferenceResponse.token() contains an incremental fragment, while
/// InferenceResponse.finalChunk() carries the complete canonical answer.
/// Concatenating the final chunk after streamed tokens duplicates the reply
/// in chat and causes the Kokoro player to read it twice.
class LiveResponseTextAssembler {
  final StringBuffer _buffer = StringBuffer();
  bool _receivedToken = false;
  bool _finalMismatch = false;

  String get text => _buffer.toString();
  bool get finalMismatch => _finalMismatch;

  /// Returns only NEW characters to show / synthesize.
  String add({required String text, required bool isFinal}) {
    if (text.isEmpty) return '';

    if (!isFinal) {
      _receivedToken = true;
      _buffer.write(text);
      return text;
    }

    if (!_receivedToken) {
      _buffer.write(text);
      return text;
    }

    final streamed = _buffer.toString();
    if (text.startsWith(streamed)) {
      final missingSuffix = text.substring(streamed.length);
      _buffer.write(missingSuffix);
      return missingSuffix;
    }

    // Some runtimes may normalize their final text differently. The already
    // streamed text may have reached TTS: never play it a second time.
    // Surface the mismatch as metadata only, without recording private text.
    _finalMismatch = true;
    return '';
  }
}
