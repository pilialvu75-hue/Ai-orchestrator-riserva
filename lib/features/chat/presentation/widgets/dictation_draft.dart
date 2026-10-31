/// Preserves typed drafts while partial speech-recognition hypotheses change.
///
/// Begin at recording start; successive interim/final hypotheses replace only
/// the recognizer's previous suffix. A manual edit rebases on the edited text.
class DictationDraftBuffer {
  String _prefix = '';
  String _lastRendered = '';

  void begin(String currentText) {
    _prefix = currentText;
    _lastRendered = currentText;
  }

  String accept({
    required String currentText,
    required String transcript,
    required bool isFinal,
  }) {
    final recognized = transcript.trim();
    if (recognized.isEmpty) return currentText;

    final prefix = currentText == _lastRendered ? _prefix : currentText;
    final needsSpace =
        prefix.isNotEmpty && !RegExp(r'\s$').hasMatch(prefix);
    final merged = '$prefix${needsSpace ? ' ' : ''}$recognized';

    _prefix = isFinal ? merged : prefix;
    _lastRendered = merged;
    return merged;
  }

  void stop(String currentText) {
    _prefix = currentText;
    _lastRendered = currentText;
  }
}
