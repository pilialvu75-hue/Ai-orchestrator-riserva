import 'package:flutter/foundation.dart';

@immutable
class VectorEntry {
  const VectorEntry({
    required this.id,
    required this.text,
    required this.embedding,
  });

  final String id;
  final String text;
  final List<double> embedding;
}

class VectorStoreService {
  final List<VectorEntry> _entries = [];

  void add(VectorEntry entry) {
    _entries.removeWhere((e) => e.id == entry.id);
    _entries.add(entry);
  }

  void remove(String id) {
    _entries.removeWhere((e) => e.id == id);
  }

  List<VectorEntry> getAll() => List.unmodifiable(_entries);

  void clear() {
    _entries.clear();
  }

  int get count => _entries.length;
}
