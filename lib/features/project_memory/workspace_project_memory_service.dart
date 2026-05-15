import 'dart:convert';

import 'package:ai_orchestrator/core/database/database_helper.dart';

class WorkspaceProjectMemoryService {
  WorkspaceProjectMemoryService({
    required DatabaseHelper databaseHelper,
  }) : _databaseHelper = databaseHelper;

  final DatabaseHelper _databaseHelper;
  static const String _memoryPrefPrefix = 'workspace_memory:';

  Future<void> saveMemory({
    required String workspaceId,
    required Map<String, dynamic> memory,
  }) async {
    await _databaseHelper.setPreference(
      '$_memoryPrefPrefix$workspaceId',
      jsonEncode(memory),
    );
  }

  Future<Map<String, dynamic>> loadMemory(String workspaceId) async {
    final raw = await _databaseHelper.getPreference('$_memoryPrefPrefix$workspaceId');
    if (raw == null || raw.trim().isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }
}

