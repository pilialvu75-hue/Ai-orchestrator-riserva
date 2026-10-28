/// Deterministic, geometry-only reflow of on-device ML Kit OCR lines.
/// No model calls, text correction, network, or inferred missing cells.
///
/// The native bridge supplies rectangles in bitmap pixel coordinates.
/// This is intentionally conservative: text is never edited, only ordered.
final class ChatLocalOcrLayoutFormatter {
  static const int maxLines = 120;
  static const int maxOutputChars = 1800;

  static String? reflow(Object? source) {
    if (source is! List || source.isEmpty || source.length > maxLines) {
      return null;
    }
    final lines = <_OcrLine>[];
    for (final entry in source) {
      if (entry is! Map) return null;
      final text = entry['text'];
      final left = entry['left'];
      final top = entry['top'];
      final right = entry['right'];
      final bottom = entry['bottom'];
      if (text is! String || text.trim().isEmpty ||
          left is! int || top is! int ||
          right is! int || bottom is! int ||
          left < 0 || top < 0 || right <= left || bottom <= top ||
          right > 16384 || bottom > 16384 || text.length > 280) {
        return null; // Unknown native format: preserve the old OCR result.
      }
      lines.add(_OcrLine(text.trim(), left, top, right, bottom));
    }

    lines.sort((a, b) {
      final y = a.centerY.compareTo(b.centerY);
      return y != 0 ? y : a.left.compareTo(b.left);
    });
    final rows = <_OcrRow>[];
    for (final line in lines) {
      _OcrRow? closest;
      var bestDistance = double.infinity;
      for (final row in rows) {
        final overlap = (line.bottom < row.bottom ? line.bottom : row.bottom) -
            (line.top > row.top ? line.top : row.top);
        final minHeight = line.height < row.smallestHeight
            ? line.height : row.smallestHeight;
        // Avoid merging adjacent paragraphs or a tall heading into a row.
        if (overlap <= 0 || overlap / minHeight < 0.55) continue;
        final distance = (line.centerY - row.centerY).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          closest = row;
        }
      }
      if (closest == null) {
        rows.add(_OcrRow(line));
      } else {
        closest.add(line);
      }
    }
    rows.sort((a, b) {
      final y = a.top.compareTo(b.top);
      return y != 0 ? y : a.left.compareTo(b.left);
    });

    final result = StringBuffer();
    _OcrRow? previous;
    for (final row in rows) {
      row.lines.sort((a, b) => a.left.compareTo(b.left));
      // Leave a paragraph break when a large vertical gap is visible.
      if (previous != null) {
        final gap = row.top - previous.bottom;
        result.write(gap > previous.smallestHeight * 1.2 ? '\n\n' : '\n');
      }
      _OcrLine? previousCell;
      for (final cell in row.lines) {
        if (previousCell != null) {
          final gap = cell.left - previousCell.right;
          final threshold = cell.height * 1.2;
          result.write(gap > threshold ? ' | ' : ' ');
        }
        result.write(cell.text);
        previousCell = cell;
      }
      previous = row;
    }
    return result.toString().trim();
  }
}

final class _OcrLine {
  const _OcrLine(this.text, this.left, this.top, this.right, this.bottom);
  final String text;
  final int left;
  final int top;
  final int right;
  final int bottom;

  int get height => bottom - top;
  double get centerY => (top + bottom) / 2;
}

final class _OcrRow {
  _OcrRow(_OcrLine first)
      : lines = <_OcrLine>[first],
        top = first.top,
        bottom = first.bottom,
        left = first.left,
        smallestHeight = first.height,
        centerY = first.centerY;

  final List<_OcrLine> lines;
  int top;
  int bottom;
  int left;
  int smallestHeight;
  double centerY;

  void add(_OcrLine line) {
    final n = lines.length;
    centerY = (centerY * n + line.centerY) / (n + 1);
    lines.add(line);
    if (line.top < top) top = line.top;
    if (line.bottom > bottom) bottom = line.bottom;
    if (line.left < left) left = line.left;
    if (line.height < smallestHeight) smallestHeight = line.height;
  }
}
