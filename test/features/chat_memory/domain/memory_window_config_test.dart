import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';

void main() {
  group('MemoryWindowConfig', () {
    test('factory presets expose normalized values', () {
      final compact = MemoryWindowConfig.compact(isWeb: false);
      final standard = MemoryWindowConfig.standard(isWeb: false);
      final performance = MemoryWindowConfig.performance(isWeb: false);

      expect(compact.profile, MemoryWindowProfile.compact);
      expect(compact.activeProfile, MemoryWindowProfile.compact);
      expect(compact.maxContextLines, 24);
      expect(compact.maxTotalSize, 3072);
      expect(compact.minContextSize, 256);

      expect(standard.profile, MemoryWindowProfile.standard);
      expect(standard.activeProfile, MemoryWindowProfile.standard);
      expect(standard.maxContextLines, 48);
      expect(standard.maxTotalSize, 4608);
      expect(standard.minContextSize, 512);

      expect(performance.profile, MemoryWindowProfile.performance);
      expect(performance.maxContextLines, 64);
      expect(performance.maxTotalSize, 6144);
      expect(performance.minContextSize, 768);
    });

    test('automatic profile follows the active model', () {
      final config = MemoryWindowConfig.automatic(
        modelId: 'tinyllama-1.1b-chat-v1.0',
        isWeb: false,
      );

      expect(config.profile, MemoryWindowProfile.automatic);
      expect(config.activeProfile, MemoryWindowProfile.compact);
      expect(config.maxTotalSize, 3072);
    });

    test('Phi-3.5 automatic profile stays compact', () {
      final config = MemoryWindowConfig.automatic(
        modelId: 'phi3_5_mini',
        isWeb: false,
      );

      expect(config.activeProfile, MemoryWindowProfile.compact);
      expect(config.maxContextLines, 24);
      expect(config.maxTotalSize, 3072);
    });

    test('custom web values clamp to conservative thresholds', () {
      final config = MemoryWindowConfig.custom(
        maxContextLines: 120,
        maxTotalSize: 16000,
        minContextSize: 9000,
        isWeb: true,
      );

      expect(config.profile, MemoryWindowProfile.custom);
      expect(config.activeProfile, MemoryWindowProfile.custom);
      expect(config.maxContextLines, 40);
      expect(config.maxTotalSize, 4096);
      expect(config.minContextSize, 4096);
    });
  });
}
