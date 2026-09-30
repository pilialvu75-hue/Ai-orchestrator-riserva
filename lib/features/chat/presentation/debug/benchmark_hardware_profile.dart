import 'benchmark_hardware_profile_common.dart';
import 'benchmark_hardware_profile_stub.dart'
    if (dart.library.io) 'benchmark_hardware_profile_io.dart' as platform;

export 'benchmark_hardware_profile_common.dart'
    show
        BenchmarkHardwareSnapshot,
        buildBenchmarkHardwareProfile,
        classifyLinuxBenchmarkDevice;

/// Collects a stable benchmark identity for the current non-Android device.
///
/// Android keeps using [ResourceSample.benchmarkHardwareProfile] because its
/// native telemetry already exposes the exact manufacturer/model/ABI/RAM data.
Future<String> benchmarkHardwareProfileForPlatform(String platformName) =>
    platform.collectBenchmarkHardwareProfile(platformName);
