import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Single-file little-endian GGUF v2/v3 layout. This is a conservative
/// size estimator, not a native model validator. Unknown tensor types,
/// split files, malformed headers or unmeasurable blocks disable partial mode.
/// Format: https://github.com/ggml-org/ggml/blob/master/docs/gguf.md
class WindowsGgufBlockSizes {
  const WindowsGgufBlockSizes._(this.modelBytes, this.blockBytes);
  final int modelBytes;
  final List<int> blockBytes;

  static Future<WindowsGgufBlockSizes?> read(String path) async {
    try {
      return await Isolate.run(() {
        final file = File(path).openSync();
        try {
          final length = file.lengthSync();
          final prefix = file.readSync(length.clamp(0, 32 * 1024 * 1024).toInt());
          return parse(prefix, length);
        } finally {
          file.closeSync();
        }
      });
    } on Object {
      return null;
    }
  }

  /// Quantization block width and stored bytes for supported GGML types.
  static const _types = <int, (int, int)>{
    0: (1, 4), 1: (1, 2), 2: (32, 18), 3: (32, 20),
    6: (32, 22), 7: (32, 24), 8: (32, 34),
    10: (256, 84), 11: (256, 110), 12: (256, 144),
    13: (256, 176), 14: (256, 210), 15: (256, 292), 30: (1, 2),
  };

  static WindowsGgufBlockSizes? parse(Uint8List header, int fileBytes) {
    try {
      if (header.length > 32 * 1024 * 1024 || header.length > fileBytes) return null;
      final reader = _GgufReader(header);
      if (reader.stringBytes(4) != 'GGUF') return null;
      final version = reader.u32();
      if (version != 2 && version != 3) return null;
      final tensors = reader.u64();
      final metadata = reader.u64();
      if (tensors < 1 || tensors > 100000 || metadata > 10000) return null;
      String? architecture;
      var alignment = 32;
      final blockCounts = <String, int>{};
      final keys = <String>{};
      for (var i = 0; i < metadata; i++) {
        final key = reader.string();
        if (!keys.add(key)) return null;
        final type = reader.u32();
        if (key == 'general.architecture' && type == 8) {
          architecture = reader.string();
        } else if (key == 'general.alignment' && type == 4) {
          alignment = reader.u32();
        } else if (key.endsWith('.block_count') && type == 4) {
          blockCounts[key] = reader.u32();
        } else if (key.startsWith('split.')) {
          // Sharded models need an all-shard estimator, not this file alone.
          return null;
        } else {
          reader.skipValue(type);
        }
      }
      final count = blockCounts['$architecture.block_count'];
      if (architecture == null || count == null || count < 2 || count > 512 ||
          alignment <= 0 || alignment > 4096 ||
          (alignment & (alignment - 1)) != 0) return null;

      final rows = <(int, int, int?)>[];
      final names = <String>{};
      final blockPattern = RegExp(r'^blk\.(\d+)\.');
      for (var i = 0; i < tensors; i++) {
        final name = reader.string();
        if (!names.add(name)) return null;
        final dimensions = reader.u32();
        if (dimensions < 1 || dimensions > 4) return null;
        final first = reader.u64();
        var rowsCount = 1;
        for (var d = 1; d < dimensions; d++) {
          final dim = reader.u64();
          if (dim <= 0 || dim > fileBytes ~/ rowsCount) return null;
          rowsCount *= dim;
        }
        final layout = _types[reader.u32()];
        final offset = reader.u64();
        if (layout == null || first <= 0 || first % layout.$1 != 0 ||
            offset % alignment != 0) return null;
        final units = first ~/ layout.$1;
        if (units > fileBytes ~/ layout.$2) return null;
        final rowBytes = units * layout.$2;
        if (rowBytes <= 0 || rowsCount > fileBytes ~/ rowBytes) return null;
        final bytes = rowsCount * rowBytes;
        final match = blockPattern.firstMatch(name);
        final block = match == null ? null : int.tryParse(match.group(1)!);
        if (match != null && (block == null || block >= count)) return null;
        rows.add((offset, bytes, block));
      }
      final dataStart = ((reader.position + alignment - 1) ~/ alignment) * alignment;
      final dataBytes = fileBytes - dataStart;
      if (dataBytes <= 0) return null;
      rows.sort((a, b) => a.$1.compareTo(b.$1));
      var previousEnd = 0;
      final sizes = List<int>.filled(count, 0);
      for (final (offset, bytes, block) in rows) {
        if (offset < previousEnd || offset > dataBytes ||
            bytes > dataBytes - offset) return null;
        previousEnd = offset + bytes;
        if (block != null) sizes[block] += bytes;
      }
      if (sizes.any((bytes) => bytes <= 0)) return null;
      return WindowsGgufBlockSizes._(fileBytes, List.unmodifiable(sizes));
    } on Object {
      return null;
    }
  }
}

class _GgufReader {
  _GgufReader(this.bytes) : data = ByteData.sublistView(bytes);
  final Uint8List bytes;
  final ByteData data;
  int position = 0;

  void skip(int count) {
    if (count < 0 || count > bytes.length - position) {
      throw const FormatException('GGUF header bounds');
    }
    position += count;
  }

  int u32() {
    final at = position;
    skip(4);
    return data.getUint32(at, Endian.little);
  }

  int u64() {
    final at = position;
    skip(8);
    final value = data.getUint64(at, Endian.little);
    if (value < 0) throw const FormatException('GGUF integer bounds');
    return value;
  }

  String stringBytes(int length) {
    final at = position;
    skip(length);
    return utf8.decode(bytes.sublist(at, position));
  }

  String string() {
    final length = u64();
    if (length > 4096) throw const FormatException('GGUF key/name bounds');
    return stringBytes(length);
  }

  static const _scalarBytes = <int, int>{
    0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1,
    10: 8, 11: 8, 12: 8,
  };

  void skipValue(int type) {
    if (type == 8) {
      skip(u64());
    } else if (type == 9) {
      final item = u32();
      final count = u64();
      if (count > 1000000) throw const FormatException('GGUF array bounds');
      if (item == 8) {
        for (var i = 0; i < count; i++) {
          skip(u64());
        }
      } else {
        final width = _scalarBytes[item];
        if (width == null) throw const FormatException('GGUF array type');
        skip(count * width);
      }
    } else {
      final width = _scalarBytes[type];
      if (width == null) throw const FormatException('GGUF metadata type');
      skip(width);
    }
  }
}
