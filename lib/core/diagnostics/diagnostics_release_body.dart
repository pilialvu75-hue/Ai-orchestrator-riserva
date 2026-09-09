import 'dart:convert';

/// Inputs must contain only previously filtered public diagnostics.
String diagnosticsReleaseBody(String filteredBatch, {String previousBody = ''}) {
  final records = <String, Map<String, dynamic>>{};
  void add(String context, Map<String, dynamic> event) {
    if (event['time'] is! String || event['event'] is! String) return;
    final record = <String, dynamic>{'context': context, 'log': event};
    // Capture session changes when disk history is recovered. Deduplicate by
    // original event payload within this installation, retaining first context.
    records.putIfAbsent(jsonEncode(event), () => record);
  }
  String context = '';
  for (final line in const LineSplitter().convert(previousBody)) {
    if (!line.startsWith('    ')) continue;
    final value = line.substring(4);
    if (value.startsWith('schema=1 ')) { context = value; continue; }
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        if (decoded['context'] is String && decoded['log'] is Map) {
          add(decoded['context'] as String,
              Map<String, dynamic>.from(decoded['log'] as Map));
        } else {
          add(context, decoded); // Migrate the previous single-batch format.
        }
      }
    } on FormatException { /* Ignore prose and incomplete records. */ }
  }
  final lines = const LineSplitter().convert(filteredBatch);
  context = lines.isEmpty ? '' : lines.first;
  for (var i = 1; i < lines.length; i++) {
    try {
      final event = jsonDecode(lines[i]);
      if (event is Map<String, dynamic>) add(context, event);
    } on FormatException { /* Never publish unstructured text. */ }
  }
  final ordered = records.values.toList()
    ..sort((a, b) => (a['log']['time'] as String).compareTo(b['log']['time'] as String));
  bool important(Map<String, dynamic> record) {
    final event = record['log']['event'] as String;
    return RegExp(r'FAIL|ERROR|TIMEOUT|STALL|BLOCKED|REJECTED|EXCEPTION|EXIT_HISTORY').hasMatch(event);
  }
  String tail(Iterable<Map<String, dynamic>> source, int budget) {
    final values = source.toList();
    final selected = <String>[];
    for (var i = values.length - 1; i >= 0; i--) {
      final line = '    ${jsonEncode(values[i])}\n';
      if (line.length > budget) continue;
      selected.add(line);
      budget -= line.length;
    }
    return selected.reversed.join();
  }
  return 'Log tecnici filtrati cumulativi. Contesto = build e sessione di raccolta, '
      'non necessariamente del crash originale. Cronologia limitata; archivio nei file allegati.\n\n'
      '### Eventi recenti\n\n'
      '${tail(ordered, 32000)}\n'
      '### Ultimi errori e arresti (possono essere storici)\n\n'
      '${tail(ordered.where(important), 12000)}';
}
