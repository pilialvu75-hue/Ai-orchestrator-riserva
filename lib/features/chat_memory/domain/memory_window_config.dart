import 'package:flutter/foundation.dart';

enum MemoryWindowProfile {
  automatic,
  compact,
  standard,
  performance,
  custom,
  ;

  static MemoryWindowProfile fromStoredValue(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'automatic':
      case 'auto':
      case 'automatico':
        return automatic;
      case 'compact':
      case '4k':
        return compact;
      case 'standard':
      case '8k':
        return standard;
      case 'performance':
      case '16k':
        return performance;
      case 'custom':
      case 'personalizzato':
        return custom;
      default:
        return automatic;
    }
  }
}

class MemoryWindowConfig {
  const MemoryWindowConfig._({
    required this.profile,
    required this.activeProfile,
    required this.maxContextLines,
    required this.maxTotalSize,
    required this.minContextSize,
  });

  static const int _desktopMaxTotalSize = 16000;
  static const int _webMaxTotalSize = 8000;
  static const int _desktopMaxContextLines = 120;
  static const int _webMaxContextLines = 80;
  static const int _minimumContextSizeFloor = 256;

  final MemoryWindowProfile profile;
  final MemoryWindowProfile activeProfile;
  final int maxContextLines;
  final int maxTotalSize;
  final int minContextSize;

  bool get isAutomatic => profile == MemoryWindowProfile.automatic;
  bool get isCustom => profile == MemoryWindowProfile.custom;
  bool get isWebSafe => maxTotalSize <= _webMaxTotalSize;

  factory MemoryWindowConfig.automatic({
    String? modelId,
    bool isWeb = kIsWeb,
  }) {
    final activeProfile = _profileForModelId(modelId);
    return _fromProfile(
      profile: MemoryWindowProfile.automatic,
      activeProfile: activeProfile,
      isWeb: isWeb,
    );
  }

  factory MemoryWindowConfig.compact({bool isWeb = kIsWeb}) {
    return _fromProfile(
      profile: MemoryWindowProfile.compact,
      activeProfile: MemoryWindowProfile.compact,
      isWeb: isWeb,
    );
  }

  factory MemoryWindowConfig.standard({bool isWeb = kIsWeb}) {
    return _fromProfile(
      profile: MemoryWindowProfile.standard,
      activeProfile: MemoryWindowProfile.standard,
      isWeb: isWeb,
    );
  }

  factory MemoryWindowConfig.performance({bool isWeb = kIsWeb}) {
    return _fromProfile(
      profile: MemoryWindowProfile.performance,
      activeProfile: MemoryWindowProfile.performance,
      isWeb: isWeb,
    );
  }

  factory MemoryWindowConfig.custom({
    required int maxContextLines,
    required int maxTotalSize,
    int? minContextSize,
    bool isWeb = kIsWeb,
  }) {
    final normalizedMaxContextLines = _clamp(
      maxContextLines,
      min: 16,
      max: isWeb ? _webMaxContextLines : _desktopMaxContextLines,
    );
    final normalizedMaxTotalSize = _clamp(
      maxTotalSize,
      min: 512,
      max: isWeb ? _webMaxTotalSize : _desktopMaxTotalSize,
    );

    final normalizedMinContextSize = minContextSize != null
        ? _clamp(minContextSize, min: 32, max: normalizedMaxTotalSize)
        : _clamp(
            _defaultMinContextSize(normalizedMaxTotalSize),
            min: _minimumContextSizeFloor,
            max: normalizedMaxTotalSize,
          );

    return MemoryWindowConfig._(
      profile: MemoryWindowProfile.custom,
      activeProfile: MemoryWindowProfile.custom,
      maxContextLines: normalizedMaxContextLines,
      maxTotalSize: normalizedMaxTotalSize,
      minContextSize: normalizedMinContextSize,
    );
  }

  static MemoryWindowConfig _fromProfile({
    required MemoryWindowProfile profile,
    required MemoryWindowProfile activeProfile,
    required bool isWeb,
  }) {
    final preset = _presetFor(activeProfile, isWeb: isWeb);
    return MemoryWindowConfig._(
      profile: profile,
      activeProfile: activeProfile,
      maxContextLines: preset.$1,
      maxTotalSize: preset.$2,
      minContextSize: preset.$3,
    );
  }

  static (int, int, int) _presetFor(
    MemoryWindowProfile profile, {
    required bool isWeb,
  }) {
    switch (profile) {
      case MemoryWindowProfile.compact:
        return (
          isWeb ? 6 : 6,
          4096,
          256,
        );
      case MemoryWindowProfile.standard:
        return (
          isWeb ? 48 : 60,
          isWeb ? _webMaxTotalSize : 8000,
          512,
        );
      case MemoryWindowProfile.performance:
        return (
          isWeb ? 60 : 96,
          isWeb ? _webMaxTotalSize : _desktopMaxTotalSize,
          isWeb ? 768 : 1024,
        );
      case MemoryWindowProfile.custom:
      case MemoryWindowProfile.automatic:
        return _presetFor(MemoryWindowProfile.standard, isWeb: isWeb);
    }
  }

  static MemoryWindowProfile _profileForModelId(String? modelId) {
    final normalized = (modelId ?? '').trim().toLowerCase();
    if (normalized.isEmpty) {
      return MemoryWindowProfile.standard;
    }

    if (_containsAny(
      normalized,
      const <String>[
        '1b',
        '1_5b',
        '1.5b',
        '2b',
        'tiny',
        'small',
      ],
    )) {
      return MemoryWindowProfile.compact;
    }

    if (_containsAny(
      normalized,
      const <String>[
        '7b',
        '8b',
        '13b',
        'qwen3',
        'deepseek',
        'phi',
        'phi3',
        'phi-3',
        'phi3.5',
        'performance',
      ],
    )) {
      return MemoryWindowProfile.compact;
    }

    return MemoryWindowProfile.standard;
  }

  static bool _containsAny(String value, List<String> needles) {
    for (final needle in needles) {
      if (value.contains(needle)) {
        return true;
      }
    }
    return false;
  }

  static int _defaultMinContextSize(int maxTotalSize) {
    final derived = maxTotalSize ~/ 8;
    if (derived < _minimumContextSizeFloor) {
      return _minimumContextSizeFloor;
    }
    if (derived > 1024) {
      return 1024;
    }
    return derived;
  }

  static int _clamp(int value, {required int min, required int max}) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}
