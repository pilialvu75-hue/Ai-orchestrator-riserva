import 'package:ai_orchestrator/core/diagnostics/chatgpt_bridge/aivexus_bridge_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemorySecretStore implements BridgeSecretStore {
  String? value;
  int deletions = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
  }

  @override
  Future<void> delete() async {
    value = null;
    deletions++;
  }
}

class _FakeHost implements BridgeControlHost {
  _FakeHost({this.failStart = false});
  final bool failStart;
  bool _running = false;
  int starts = 0;
  int stops = 0;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start() async {
    starts++;
    if (failStart) throw StateError('test_fail');
    _running = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    _running = false;
  }
}

void main() {
  test('disabled builds never create a secret or start a server', () async {
    final store = _MemorySecretStore();
    final controller = AivexusBridgeController(
      allowed: false,
      secretStore: store,
      buildHost: (_) => _FakeHost(),
    );
    await controller.restore();
    expect(controller.isEnabled, isFalse);
    await expectLater(controller.enable(), throwsStateError);
    expect(store.value, isNull);
  });

  test('the first user tap generates a strong credential and starts bridge',
      () async {
    final store = _MemorySecretStore();
    String? passed;
    final host = _FakeHost();
    final controller = AivexusBridgeController(
      allowed: true,
      secretStore: store,
      buildHost: (token) {
        passed = token;
        return host;
      },
    );
    await controller.restore();
    expect(store.value, isNull, reason: 'No silent opt-in');
    await controller.enable();
    expect(controller.isEnabled, isTrue);
    expect(store.value, isNotNull);
    expect(store.value!.length, greaterThanOrEqualTo(32));
    expect(passed, store.value);
    expect(await controller.pairingKeyForExplicitCopy(), store.value);
    await controller.enable();
    expect(host.starts, 1);
  });

  test('revocation immediately stops bridge and erases local pairing key',
      () async {
    final store = _MemorySecretStore();
    final host = _FakeHost();
    final controller = AivexusBridgeController(
      allowed: true,
      secretStore: store,
      buildHost: (_) => host,
    );
    await controller.enable();
    await controller.disable();
    expect(host.stops, 1);
    expect(controller.isEnabled, isFalse);
    expect(store.value, isNull);
    expect(await controller.pairingKeyForExplicitCopy(), isNull);
  });

  test('restart requires a new explicit activation even with an existing key',
      () async {
    final store = _MemorySecretStore();
    final original = AivexusBridgeController(
      allowed: true,
      secretStore: store,
      buildHost: (_) => _FakeHost(),
    );
    await original.enable();
    final key = store.value;
    final restored = AivexusBridgeController(
      allowed: true,
      secretStore: store,
      buildHost: (_) => _FakeHost(),
    );
    await restored.restore();
    expect(restored.isEnabled, isFalse);
    expect(store.value, key);
    await restored.enable();
    expect(restored.isEnabled, isTrue);
  });

  test('failed enable does not retain new secret', () async {
    final store = _MemorySecretStore();
    final controller = AivexusBridgeController(
      allowed: true,
      secretStore: store,
      buildHost: (_) => _FakeHost(failStart: true),
    );
    await expectLater(controller.enable(), throwsStateError);
    expect(controller.isEnabled, isFalse);
    expect(store.value, isNull);
  });

  test('rotate invalidates old key and leaves only new key active', () async {
    final store = _MemorySecretStore();
    final controller = AivexusBridgeController(
      allowed: true,
      secretStore: store,
      buildHost: (_) => _FakeHost(),
    );
    await controller.enable();
    final old = store.value;
    await controller.rotateKey();
    expect(controller.isEnabled, isTrue);
    expect(store.value, isNot(old));
    expect(store.deletions, greaterThan(0));
  });
}
