import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/presentation/chat/components/runtime_metrics_widget.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/runtime_state_controller.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/execution_hardware_controller.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/system_indicators_controller.dart';

void main() {
  testWidgets(
      'open metrics follows runtime, hardware and mode without reopening',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('com.aiorchestrator/resources');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => <String, Object>{
        'availableBytes': 3 << 30,
        'totalBytes': 8 << 30,
        'thresholdBytes': 256 << 20,
        'lowMemory': false,
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final runtime = ValueNotifier(const ChatRuntimeSnapshot());
    final hardware = ValueNotifier(const HardwareSnapshot());
    final system =
        ValueNotifier(const SystemIndicatorsSnapshot(runtimeModeName: 'local'));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.topLeft,
      child: LiveRuntimeMetricsWidget(
          runtime: runtime, hardware: hardware, system: system),
    ))));
    expect(find.text('Tokens generated: 0'), findsOneWidget);
    runtime.value = const ChatRuntimeSnapshot(
        state: LocalRuntimeState(
      status: LocalRuntimeStatus.streaming,
      tokensGenerated: 7,
      elapsed: Duration(seconds: 9),
    ));
    hardware.value = const HardwareSnapshot(gpuBackend: 'vulkan');
    system.value = const SystemIndicatorsSnapshot(runtimeModeName: 'cloud');
    await tester.pump();
    expect(find.text('Tokens generated: 7'), findsOneWidget);
    expect(find.text('Elapsed: 9s'), findsOneWidget);
    expect(find.text('STREAMING • cloud'), findsOneWidget);
    expect(find.text('Backend compilato: VULKAN'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    // Let the last bounded sensor request finish after the panel releases its lease.
    await tester.pump(const Duration(seconds: 1));
    runtime.dispose();
    hardware.dispose();
    system.dispose();
    expect(tester.takeException(), isNull);
  });
}
