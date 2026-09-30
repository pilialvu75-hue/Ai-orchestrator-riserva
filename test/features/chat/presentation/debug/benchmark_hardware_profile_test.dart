import 'package:ai_orchestrator/features/chat/presentation/debug/benchmark_hardware_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Raspberry Pi is a distinct Linux benchmark device class', () {
    expect(
      classifyLinuxBenchmarkDevice(
        boardModel: 'Raspberry Pi 5 Model B Rev 1.0',
      ),
      'raspberry_pi',
    );
    expect(
      classifyLinuxBenchmarkDevice(
        productName: 'ThinkPad T14 Gen 4',
      ),
      'desktop',
    );
  });

  test('hardware profile includes performance-relevant device identity', () {
    const snapshot = BenchmarkHardwareSnapshot(
      platform: 'windows',
      deviceClass: 'desktop',
      manufacturer: 'Example Corp',
      model: 'Workstation 16',
      cpu: 'Example CPU 12-Core',
      gpu: 'Example GPU',
      architecture: 'AMD64',
      totalMemoryBytes: 34359738368,
      osVersion: 'Windows 11',
    );

    expect(
      buildBenchmarkHardwareProfile(snapshot),
      'hardware-v2|platform:windows|class:desktop|'
      'manufacturer:Example Corp|model:Workstation 16|'
      'cpu:Example CPU 12-Core|gpu:Example GPU|arch:AMD64|'
      'ram:34359738368|os:Windows 11',
    );
  });

  test('different GPU or RAM produces a different benchmark profile', () {
    const base = BenchmarkHardwareSnapshot(
      platform: 'linux',
      deviceClass: 'desktop',
      model: 'Desktop',
      cpu: 'CPU',
      gpu: 'GPU-A',
      architecture: 'x86_64',
      totalMemoryBytes: 17179869184,
      osVersion: 'Linux',
    );
    const differentGpu = BenchmarkHardwareSnapshot(
      platform: 'linux',
      deviceClass: 'desktop',
      model: 'Desktop',
      cpu: 'CPU',
      gpu: 'GPU-B',
      architecture: 'x86_64',
      totalMemoryBytes: 17179869184,
      osVersion: 'Linux',
    );
    const differentRam = BenchmarkHardwareSnapshot(
      platform: 'linux',
      deviceClass: 'desktop',
      model: 'Desktop',
      cpu: 'CPU',
      gpu: 'GPU-A',
      architecture: 'x86_64',
      totalMemoryBytes: 34359738368,
      osVersion: 'Linux',
    );

    final baseProfile = buildBenchmarkHardwareProfile(base);
    expect(buildBenchmarkHardwareProfile(differentGpu), isNot(baseProfile));
    expect(buildBenchmarkHardwareProfile(differentRam), isNot(baseProfile));
  });

  test('profile values cannot break the field boundary', () {
    const snapshot = BenchmarkHardwareSnapshot(
      platform: 'linux',
      deviceClass: 'desktop',
      model: 'Model|A\nRevision 2',
    );

    final profile = buildBenchmarkHardwareProfile(snapshot);
    expect(profile, contains('model:Model A Revision 2'));
    expect(profile.split('|').length, 10);
  });
}
