import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bundled model manifest download regressions', () {
    late Map<String, dynamic> manifest;

    setUpAll(() async {
      final raw = await File('assets/models/manifest.json').readAsString();
      manifest = jsonDecode(raw) as Map<String, dynamic>;
    });

    test('Qwen3 8B points to the current Bartowski Q4_K_M object', () {
      final entry = manifest['qwen3_8b'] as Map<String, dynamic>;

      expect(entry['fileName'], 'Qwen_Qwen3-8B-Q4_K_M.gguf');
      expect(
        entry['downloadUrl'],
        'https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf',
      );
      expect(entry['sizeBytes'], 5030000000);
    });

    test('DeepSeek Coder points to the recommended Q4_K_M object', () {
      final entry =
          manifest['deepseek_coder_6_7b_instruct'] as Map<String, dynamic>;

      expect(entry['fileName'], 'deepseek-coder-6.7b-instruct-Q4_K_M.gguf');
      expect(
        entry['downloadUrl'],
        'https://huggingface.co/tensorblock/deepseek-coder-6.7b-instruct-GGUF/resolve/main/deepseek-coder-6.7b-instruct-Q4_K_M.gguf',
      );
      expect(entry['sizeBytes'], 3802000000);
    });

    test('StarCoder2 points to the recommended Q4_K_M object', () {
      final entry = manifest['starcoder2_3b'] as Map<String, dynamic>;

      expect(entry['fileName'], 'starcoder2-3b-Q4_K_M.gguf');
      expect(
        entry['downloadUrl'],
        'https://huggingface.co/tensorblock/starcoder2-3b-GGUF/resolve/main/starcoder2-3b-Q4_K_M.gguf',
      );
      expect(entry['sizeBytes'], 1758000000);
    });

    test('legacy workshop Q3 filenames are no longer selected', () {
      final fileNames = manifest.values
          .whereType<Map<String, dynamic>>()
          .map((entry) => entry['fileName'])
          .whereType<String>()
          .toList();

      expect(fileNames, isNot(contains('Qwen3-8B-Q4_K_M.gguf')));
      expect(
        fileNames,
        isNot(contains('deepseek-coder-6.7b-instruct-Q3_K_M.gguf')),
      );
      expect(fileNames, isNot(contains('starcoder2-3b-Q3_K_M.gguf')));
    });
  });
}
