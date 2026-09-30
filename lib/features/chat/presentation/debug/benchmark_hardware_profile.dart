import 'package:ai_orchestrator/features/chat/presentation/debug/benchmark_hardware_profile_stub.dart'
    if (dart.library.io) 'package:ai_orchestrator/features/chat/presentation/debug/benchmark_hardware_profile_io.dart' as platform;

export 'package:ai_orchestrator/features/chat/presentation/debug/benchmark_hardware_profile_common.dart'
    show
        BenchmarkHardwareSnapshot,
        buildBenchmarkHardwareProfile,
        classifyLinuxBenchmarkDevice;

/// Collects a stable benchmark identity for the current non-Android device.
///
/// Android keeps using its native resource telemetry because it already
/// exposes the exact manufacturer/model/ABI/RAM data.
Future<String> benchmarkHardwareProfileForPlatform(String platformName) =>
    platform.collectBenchmarkHardwareProfile(platformName);
