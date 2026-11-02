import 'package:ai_orchestrator/core/runtime/inference/hybrid_validated_connectivity.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/hybrid_validated_connectivity');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('Android validated connection queries the OS once on demand',
      () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
    const adapter = HybridValidatedConnectivity(
      channel: channel,
      platformOverride: TargetPlatform.android,
    );
    expect(calls, isEmpty); // No background polling at construction.
    expect(await adapter.isNetworkAvailable(), isTrue);
    expect(calls, ['hasValidatedInternet']);
    expect(await adapter.isNetworkAvailable(), isTrue);
    expect(calls, ['hasValidatedInternet', 'hasValidatedInternet']);
  });

  test('validated status false means offline without any network probe',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return false;
    });
    const adapter = HybridValidatedConnectivity(
      channel: channel,
      platformOverride: TargetPlatform.android,
    );
    expect(await adapter.isNetworkAvailable(), isFalse);
    expect(calls, 1);
  });

  test('missing native implementation fails closed to Local', () async {
    const adapter = HybridValidatedConnectivity(
      channel: channel,
      platformOverride: TargetPlatform.android,
    );
    expect(await adapter.isNetworkAvailable(), isFalse);
  });

  test('native error or missing boolean fails closed to Local', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'NO_NETWORK_PERMISSION');
    });
    const adapter = HybridValidatedConnectivity(
      channel: channel,
      platformOverride: TargetPlatform.android,
    );
    expect(await adapter.isNetworkAvailable(), isFalse);
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await adapter.isNetworkAvailable(), isFalse);
  });

  test('unsupported platform cannot enable Cloud through Android channel',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return true;
    });
    const adapter = HybridValidatedConnectivity(
      channel: channel,
      platformOverride: TargetPlatform.windows,
    );
    expect(await adapter.isNetworkAvailable(), isFalse);
    expect(calls, 0);
  });
}
