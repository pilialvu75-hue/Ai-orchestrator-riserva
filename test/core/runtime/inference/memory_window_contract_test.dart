import 'package:ai_orchestrator/core/runtime/inference/memory_window_config.dart'
    as core;
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart'
    as legacy;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy memory-window path re-exports the canonical core contract', () {
    final coreConfig = core.MemoryWindowConfig.compact(isWeb: false);

    final legacy.MemoryWindowConfig legacyConfig = coreConfig;

    expect(legacyConfig.profile, core.MemoryWindowProfile.compact);
    expect(
      legacy.MemoryWindowProfile.compact,
      core.MemoryWindowProfile.compact,
    );
  });
}
