String mergeStreamedText({
  required String currentText,
  required String incomingText,
  required bool isFinalChunk,
}) {
  if (incomingText.isEmpty) return currentText;
  if (currentText.isEmpty) return incomingText;

  if (!isFinalChunk) {
    return '$currentText$incomingText';
  }

  // Most runtimes emit a full snapshot as the final chunk. Some runtimes emit
  // only the remaining delta; in that case incoming text can be shorter.
  if (incomingText.length >= currentText.length) {
    return incomingText;
  }

  return '$currentText$incomingText';
}
