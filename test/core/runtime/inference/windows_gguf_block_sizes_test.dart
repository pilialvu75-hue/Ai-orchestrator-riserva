import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_orchestrator/native/runtime/windows/windows_gguf_block_sizes.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List fixture({int secondOffset = 160, int secondType = 12,
    String secondName = 'blk.1.weight', bool split = false}) {
  final b = BytesBuilder();
  void u32(int n) => b.add((ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List());
  void u64(int n) => b.add((ByteData(8)..setUint64(0, n, Endian.little)).buffer.asUint8List());
  void string(String s) {
    final bytes = utf8.encode(s);
    u64(bytes.length);
    b.add(bytes);
  }
  b.add(ascii.encode('GGUF'));
  u32(3);
  u64(2);
  u64(split ? 3 : 2);
  string('general.architecture'); u32(8); string('qwen3');
  string('qwen3.block_count'); u32(4); u32(2);
  if (split) {
    string('split.count'); u32(4); u32(2);
  }
  void tensor(String name, int type, int offset) {
    string(name); u32(1); u64(256); u32(type); u64(offset);
  }
  tensor('blk.0.weight', 12, 0);
  tensor(secondName, secondType, secondOffset);
  final padding = (32 - b.length % 32) % 32;
  b.add(Uint8List(padding + 320));
  return b.takeBytes();
}

void main() {
  test('unsupported tensor reports a fixed reason rather than generic memory error', () {
    final bytes = fixture(secondType: 999);
    String? reason;
    expect(WindowsGgufBlockSizes.parse(bytes, bytes.length,
      onReject: (code) => reason = code), isNull);
    expect(reason, 'unsupported_tensor_type_999');
  });

  test('reads exact quantized storage bytes, not alignment padding', () {
    final bytes = fixture();
    final result = WindowsGgufBlockSizes.parse(bytes, bytes.length)!;
    expect(result.modelBytes, bytes.length);
    expect(result.blockBytes, [144, 144]);
  });

  test('rejects overlap, unknown type, missing block, split and truncation', () {
    for (final bytes in [
      fixture(secondOffset: 32),
      fixture(secondType: 999),
      fixture(secondName: 'output.weight'),
      fixture(split: true),
      Uint8List.fromList(fixture().take(30).toList()),
    ]) {
      expect(WindowsGgufBlockSizes.parse(bytes, bytes.length), isNull);
    }
    final bytes = fixture();
    expect(WindowsGgufBlockSizes.parse(bytes, bytes.length - 1), isNull);
  });
}
