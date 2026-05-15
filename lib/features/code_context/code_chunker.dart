class CodeChunk {
  const CodeChunk({
    required this.documentPath,
    required this.chunkIndex,
    required this.text,
  });

  final String documentPath;
  final int chunkIndex;
  final String text;
}

class CodeChunker {
  const CodeChunker({
    this.maxChunkChars = 1200,
    this.overlapChars = 120,
  });

  final int maxChunkChars;
  final int overlapChars;

  List<CodeChunk> chunkFile({
    required String documentPath,
    required String content,
  }) {
    if (content.trim().isEmpty) return const <CodeChunk>[];
    final chunks = <CodeChunk>[];
    var start = 0;
    var index = 0;
    while (start < content.length) {
      final end = (start + maxChunkChars).clamp(0, content.length);
      final text = content.substring(start, end).trim();
      if (text.isNotEmpty) {
        chunks.add(CodeChunk(
          documentPath: documentPath,
          chunkIndex: index++,
          text: text,
        ));
      }
      if (end >= content.length) break;
      start = end - overlapChars;
      if (start < 0) start = 0;
    }
    return chunks;
  }
}

