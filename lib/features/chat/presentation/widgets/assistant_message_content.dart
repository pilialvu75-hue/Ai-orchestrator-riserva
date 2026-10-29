import 'package:flutter/material.dart';

/// Renders explicit Markdown pipe tables from assistant messages as accessible,
/// horizontally scrollable Flutter tables. Everything else remains plain text.
///
/// It does not invent cells, infer tables from prose, contact a service, or
/// modify the original message (copy, persistence and TTS use the raw text).
class AssistantMessageContent extends StatelessWidget {
  const AssistantMessageContent({
    super.key,
    required this.content,
    required this.style,
  });

  final String content;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final segments = _splitContent(content);
    if (segments.length == 1 && segments.single.table == null) {
      return Text(content, style: style);
    }

    final widgets = <Widget>[];
    for (final segment in segments) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: 8));
      }
      if (segment.table != null) {
        widgets.add(_buildTable(segment.table!));
      } else {
        widgets.add(Text(segment.text!, style: style));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }

  Widget _buildTable(_MarkdownTable table) {
    final tableStyle = style.copyWith(
      fontSize: (style.fontSize ?? 15).clamp(11.0, 14.0).toDouble(),
      height: 1.35,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF1C2736),
          border: Border.all(color: const Color(0x33FFFFFF)),
          borderRadius: BorderRadius.circular(9),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            horizontalMargin: 10,
            columnSpacing: 16,
            headingRowHeight: 42,
            dataRowMinHeight: 40,
            dataRowMaxHeight: 96,
            dividerThickness: 0.5,
            border: TableBorder.symmetric(
              inside: const BorderSide(color: Color(0x33FFFFFF), width: 0.5),
            ),
            headingTextStyle: tableStyle.copyWith(
              fontWeight: FontWeight.w700,
              color: const Color(0xFFB9D5FF),
            ),
            dataTextStyle: tableStyle,
            columns: [
              for (final heading in table.headers)
                DataColumn(
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 190),
                    child: Text(heading, softWrap: true),
                  ),
                ),
            ],
            rows: [
              for (final row in table.rows)
                DataRow(cells: [
                  for (final value in row)
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 190),
                        child: Text(value, softWrap: true),
                      ),
                    ),
                ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContentSegment {
  const _ContentSegment.text(this.text) : table = null;
  const _ContentSegment.table(this.table) : text = null;
  final String? text;
  final _MarkdownTable? table;
}

class _MarkdownTable {
  const _MarkdownTable(this.headers, this.rows, this.endIndex);
  final List<String> headers;
  final List<List<String>> rows;
  final int endIndex;
}

List<_ContentSegment> _splitContent(String content) {
  // Small LOCAL models sometimes emit the complete Markdown table on a
  // single logical line, using '||' in place of row boundaries. This only
  // changes rendering; the raw answer remains untouched for copy and TTS.
  final collapsed = _parseCollapsedTable(content);
  if (collapsed != null) {
    return <_ContentSegment>[_ContentSegment.table(collapsed)];
  }
  final lines = content.replaceAll('\r\n', '\n').split('\n');
  final segments = <_ContentSegment>[];
  final plain = <String>[];
  String? codeFence;
  var i = 0;

  void flushPlain() {
    if (plain.isNotEmpty) {
      segments.add(_ContentSegment.text(plain.join('\n')));
      plain.clear();
    }
  }

  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      final marker = trimmed.substring(0, 3);
      if (codeFence == null) {
        codeFence = marker;
      } else if (marker == codeFence) {
        codeFence = null;
      }
      plain.add(line);
      i++;
      continue;
    }

    if (codeFence == null && i + 2 < lines.length) {
      final table = _parseTable(lines, i);
      if (table != null) {
        flushPlain();
        segments.add(_ContentSegment.table(table));
        i = table.endIndex;
        continue;
      }
    }
    plain.add(line);
    i++;
  }
  flushPlain();
  return segments;
}

_MarkdownTable? _parseTable(List<String> lines, int start) {
  final headers = _pipeCells(lines[start]);
  final separators = _pipeCells(lines[start + 1]);
  if (headers == null ||
      separators == null ||
      headers.length < 2 ||
      headers.length > 8 ||
      headers.length != separators.length ||
      headers.any((value) => value.isEmpty || value.length > 190) ||
      !separators.every(
        (value) => RegExp(r'^:?-{3,}:?$').hasMatch(value),
      )) {
    return null;
  }

  final rows = <List<String>>[];
  var i = start + 2;
  while (i < lines.length) {
    final cells = _pipeCells(lines[i]);
    if (cells == null || cells.length != headers.length) break;
    if (cells.any((value) => value.length > 500)) return null;
    if (rows.length == 30) return null;
    rows.add(cells);
    i++;
  }
  // Do not turn an unfinished streamed table header into a broken widget.
  if (rows.isEmpty) return null;
  return _MarkdownTable(headers, rows, i);
}

/// Recover only a complete and unambiguous pipe table flattened into one
/// line. A separator row and exactly matching cell counts are mandatory.
/// Deliberately no general-purpose Markdown repair or source inference.
/// Reject partial streaming, embedded prose, escaped pipes and empty cells.
_MarkdownTable? _parseCollapsedTable(String source) {
  if (source.length > 2500 ||
      source.contains('\n') ||
      !source.contains('||')) {
    return null;
  }
  var text = source.trim();
  // Phi may wrap its entire table in a one-line markdown fence.
  // Never unwrap a multiline code sample or a fence embedded in prose.
  if (text.startsWith('```markdown')) {
    if (!text.endsWith('```')) return null;
    text = text.substring('```markdown'.length, text.length - 3).trim();
  }
  if (!text.startsWith('|') ||
      !text.endsWith('|') ||
      text.contains('```') ||
      text.contains('~~~') ||
      text.contains(r'\|') ||
      text.contains('|||')) {
    return null;
  }

  final parts = text.split(RegExp(r'\|\s*\|'));
  if (parts.length < 3 || parts.length > 32) return null;
  final table = _parseTable(parts, 0);
  if (table == null || table.endIndex != parts.length) return null;
  // A true empty cell also looks like '||'; we must not guess whether it
  // was intended as an empty cell or a row boundary.
  if (table.rows.any((row) => row.any((cell) => cell.isEmpty))) {
    return null;
  }
  return table;
}

List<String>? _pipeCells(String line) {
  final raw = line.trim();
  if (!raw.contains('|')) return null;
  final cells = <String>[];
  final buffer = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final char = raw[i];
    if (char.codeUnitAt(0) == 92 && i + 1 < raw.length && raw[i + 1] == '|') {
      buffer.write('|');
      i++;
    } else if (char == '|') {
      cells.add(buffer.toString().trim());
      buffer.clear();
    } else {
      buffer.write(char);
    }
  }
  cells.add(buffer.toString().trim());
  if (raw.startsWith('|')) cells.removeAt(0);
  if (raw.endsWith('|')) cells.removeLast();
  return cells;
}
