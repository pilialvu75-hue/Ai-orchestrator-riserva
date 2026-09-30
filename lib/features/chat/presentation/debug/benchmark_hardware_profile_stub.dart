import 'benchmark_hardware_profile_common.dart';

Future<String> collectBenchmarkHardwareProfile(String platformName) async {
  return buildBenchmarkHardwareProfile(
    BenchmarkHardwareSnapshot(
      platform: platformName,
      deviceClass: 'unknown',
    ),
  );
}
