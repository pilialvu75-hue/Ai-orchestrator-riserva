import 'dart:async';

import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _Persistence implements AssistantDurableMemoryPersistence {
  final Map<String, String> values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  late AssistantDurableMemoryService service;
  late AssistantDurableMemoryCaptureService capture;
  const userId = AssistantDurableMemoryContextService.localUserScopeId;

  Future<void> seed(String key, String content, {int time = 20}) =>
      service.recordConfirmed(
        recordKey: key,
        scope: AssistantMemoryScope.user,
        scopeId: userId,
        kind: AssistantMemoryKind.fact,
        content: content,
        source: AssistantMemorySource.userExplicit,
        updatedAt: time,
      );

  setUp(() {
    service = AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(persistence: _Persistence()),
    );
    capture = AssistantDurableMemoryCaptureService(memoryService: service);
  });

  test('selected confirmed fact is removed, other facts survive', () async {
    await seed('moto', 'La moto è blu');
    await seed('budget', 'Il budget è 420');
    final shown = await capture.loadReviewableConfirmedUserMemory();
    expect(shown, hasLength(2));
    expect(await capture.forgetReviewedConfirmedUserMemory(
      reviewed: shown.singleWhere((item) => item.recordKey == 'moto'),
    ), isFalse);
    expect(await capture.forgetReviewedConfirmedUserMemory(
      reviewed: shown.singleWhere((item) => item.recordKey == 'moto'),
      userConfirmed: true,
    ), isTrue);
    final later = await capture.loadReviewableConfirmedUserMemory();
    expect(later.map((item) => item.recordKey), <String>['budget']);
  });

  test('stale deletion cannot remove a newer correction', () async {
    await seed('budget', 'Il budget è 420');
    final before = (await capture.loadReviewableConfirmedUserMemory()).single;
    await seed('budget', 'Il budget è 680', time: 21);
    expect(await capture.forgetReviewedConfirmedUserMemory(
      reviewed: before,
      userConfirmed: true,
    ), isFalse);
    expect((await capture.loadReviewableConfirmedUserMemory()).single.content,
        'Il budget è 680');
  });

  test('different value at the same millisecond also blocks stale delete',
      () async {
    await seed('budget', 'Il budget è 420');
    final before = (await capture.loadReviewableConfirmedUserMemory()).single;
    await seed('budget', 'Il budget è 680', time: 20);
    expect(await capture.forgetReviewedConfirmedUserMemory(
      reviewed: before,
      userConfirmed: true,
    ), isFalse);
    expect((await capture.loadReviewableConfirmedUserMemory()).single.content,
        'Il budget è 680');
  });

  test('other scopes and model candidates are not exposed or forgotten',
      () async {
    await seed('keep', 'Remember the travel plan');
    await service.recordConfirmed(
      recordKey: 'conversation-secret',
      scope: AssistantMemoryScope.conversation,
      scopeId: 'another-chat',
      kind: AssistantMemoryKind.fact,
      content: 'Only in this conversation',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 30,
    );
    await service.recordModelCandidate(
      recordKey: 'unconfirmed',
      scope: AssistantMemoryScope.user,
      scopeId: userId,
      kind: AssistantMemoryKind.fact,
      content: 'A made-up claim',
      updatedAt: 31,
    );
    final shown = await capture.loadReviewableConfirmedUserMemory();
    expect(shown.map((item) => item.recordKey), <String>['keep']);
    final foreign = (await service.loadConfirmed(
      scope: AssistantMemoryScope.conversation,
      scopeId: 'another-chat',
    )).single;
    expect(await capture.forgetReviewedConfirmedUserMemory(
      reviewed: foreign,
      userConfirmed: true,
    ), isFalse);
    expect((await service.loadConfirmed(
      scope: AssistantMemoryScope.conversation,
      scopeId: 'another-chat',
    )), hasLength(1));
  });

  test('reset barrier refuses a late delete', () async {
    await seed('budget', 'Il budget è 420');
    final shown = (await capture.loadReviewableConfirmedUserMemory()).single;
    final entered = Completer<void>();
    final release = Completer<void>();
    final reset = capture.runWithResetBarrier(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    expect(await capture.forgetReviewedConfirmedUserMemory(
      reviewed: shown,
      userConfirmed: true,
    ), isFalse);
    release.complete();
    await reset;
    expect(await capture.loadReviewableConfirmedUserMemory(), hasLength(1));
  });
}
