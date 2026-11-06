import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_local_identity.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryProtectedStore implements HybridCloudConsentStorage {
  final data = <String, String>{};
  bool dropReads = false;

  @override
  Future<String?> read(String key) async =>
      dropReads ? null : data[key];

  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

void main() {
  test('protected installation identity survives restart but session rotates',
      () async {
    final store = _MemoryProtectedStore();
    final first = HybridCloudLocalIdentity(storage: store);
    final a = await first.openSession();
    expect(a.ownerId, startsWith('device-'));
    expect(a.ownerId, hasLength(71));
    expect(await first.isAuthorized(a.ownerId, a.sessionId), isTrue);
    first.endSession();
    expect(await first.isAuthorized(a.ownerId, a.sessionId), isFalse);

    final again = HybridCloudLocalIdentity(storage: store);
    final b = await again.openSession();
    expect(b.ownerId, a.ownerId);
    expect(b.sessionId, isNot(a.sessionId));
    expect(await again.isAuthorized(a.ownerId, a.sessionId), isFalse);
    expect(await again.isAuthorized(b.ownerId, b.sessionId), isTrue);
    expect(store.data.values.single, isNot(contains(a.ownerId)));
  });

  test('tampered protected record invalidates active consent session',
      () async {
    final store = _MemoryProtectedStore();
    final identity = HybridCloudLocalIdentity(storage: store);
    final session = await identity.openSession();
    store.data[store.data.keys.single] = 'not-valid';
    expect(await identity.isAuthorized(
        session.ownerId, session.sessionId), isFalse);
  });

  test('failed write readback never creates an authorized principal',
      () async {
    final store = _MemoryProtectedStore()..dropReads = true;
    final identity = HybridCloudLocalIdentity(storage: store);
    await expectLater(identity.openSession(), throwsStateError);
    expect(await identity.isAuthorized('device-anything', 'session'),
        isFalse);
  });

  test('identity cannot be opened from a malformed persisted record',
      () async {
    final store = _MemoryProtectedStore();
    store.data['aivexus.hybrid.local_identity.v1'] = 'bad';
    final identity = HybridCloudLocalIdentity(storage: store);
    await expectLater(identity.openSession(), throwsStateError);
  });
}
