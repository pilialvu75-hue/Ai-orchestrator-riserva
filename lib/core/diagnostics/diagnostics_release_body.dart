import 'dart:convert';

/// Bounded connector-readable copy of an already filtered diagnostic batch.
/// Never pass raw runtime or crash logs here.
String diagnosticsReleaseBody(String filteredBatch) {
  final lines = const LineSplitter().convert(filteredBatch);
  final header = lines.isEmpty ? '' : lines.first;
  final selected = <String>[];
  var remaining = 48000 - header.length - 5;
  for (final line in lines.skip(1).toList().reversed) {
    if (line.length + 5 > remaining) break;
    selected.add(line);
    remaining -= line.length + 5;
  }
  // Indented code keeps any content inert as Markdown, including backticks.
  final excerpt = [header, ...selected.reversed].map((line) => '    $line').join('\n');
  return 'Log tecnici filtrati: ultimo lotto ricevuto, non cronologia completa.\n'
      'Archivio completo nei file allegati, limite 20 MiB per dispositivo.\n'
      'Questo riepilogo viene sostituito a ogni invio.\n\n'
      '$excerpt\n';
}
