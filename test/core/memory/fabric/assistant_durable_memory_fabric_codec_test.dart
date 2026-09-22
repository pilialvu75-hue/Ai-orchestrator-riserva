import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/fabric/assistant_durable_memory_fabric_codec.dart';
import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy durable memory maps to device-only fabric record by default', () {
    final legacy = AssistantDurableMemoryRecord(
      recordKey: 'project.status',
      scope: AssistantMemoryScope.project,
      scopeId: 'project-42',
      kind: AssistantMemoryKind.state,
      content: 'blocked',
      source: AssistantMemorySource.projectEvent,
      updatedAt: DateTime.utc(2026, 9, 22, 8).millisecondsSinceEpoch,
      status: AssistantMemoryStatus.confirmed,
      before: 'running',
      after: 'blocked',
      reason: 'CI failure',
    );

    final fabric = AssistantDurableMemoryFabricCodec.toFabric(legacy);

    expect(fabric.namespace, AssistantDurableMemoryFabricCodec.namespace);
    expect(fabric.type, MemoryFabricType.project);
    expect(fabric.projectId, 'project-42');
    expect(fabric.privacyLevel, MemoryFabricPrivacyLevel.deviceOnly);
    expect(fabric.checksumValid, isTrue);
    expect(fabric.structuredData['assistant_status'], 'confirmed');
    expect(fabric.structuredData['reason'], 'CI failure');
  });

  test('legacy durable memory round-trips through canonical wire record', () {
    final legacy = AssistantDurableMemoryRecord(
      recordKey: 'language.preference',
      scope: AssistantMemoryScope.user,
      scopeId: 'local-user',
      kind: AssistantMemoryKind.preference,
      content: 'Italian',
      source: AssistantMemorySource.userExplicit,
      updatedAt: DateTime.utc(2026, 9, 22, 8, 30).millisecondsSinceEpoch,
      status: AssistantMemoryStatus.confirmed,
    );

    final encoded = AssistantDurableMemoryFabricCodec.toFabric(
      legacy,
      privacyLevel: MemoryFabricPrivacyLevel.private,
    );
    final wire = MemoryFabricRecord.fromJson(encoded.toJson());
    final restored = AssistantDurableMemoryFabricCodec.tryFromFabric(wire);

    expect(restored, isNotNull);
    expect(restored!.recordKey, legacy.recordKey);
    expect(restored.scope, legacy.scope);
    expect(restored.scopeId, legacy.scopeId);
    expect(restored.kind, legacy.kind);
    expect(restored.content, legacy.content);
    expect(restored.source, legacy.source);
    expect(restored.status, legacy.status);
    expect(restored.updatedAt, legacy.updatedAt);
  });

  test('non-assistant fabric records are not decoded as legacy memory', () {
    final record = MemoryFabricRecord.create(
      namespace: 'airlab.project',
      type: MemoryFabricType.project,
      subject: 'state',
      content: 'running',
      source: 'cantiere',
    );

    expect(
      AssistantDurableMemoryFabricCodec.tryFromFabric(record),
      isNull,
    );
  });
}
