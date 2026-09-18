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
    required this.maxContinuityContextLines,
    required this.maxTotalSize,
    required this.minContextSize,
  });

  /*
   * ---------------------------------------------------------------------------
   * RUNTIME SAFETY
   * ---------------------------------------------------------------------------
   *
   * Android llama.cpp uses nCtx=4096 and applies the final prompt-capacity
   * bound with the exact tokenizer of the loaded GGUF model.
   *
   * [maxTotalSize] remains character-based for persisted-setting compatibility
   * and legacy callers. Production conversational routing does not treat it as
   * Android's token-capacity authority.
   */

  /// Limite massimo storico del profilo desktop/manuale performance.
  ///
  /// Manteniamo questo valore per compatibilità con il profilo PERFORMANCE
  /// esistente e con le impostazioni utente.
  static const int _desktopMaxTotalSize = 6144;

  /// Limite massimo web.
  static const int _webMaxTotalSize = 4096;

  /// Limite assoluto delle righe per piattaforma desktop/non-web.
  static const int _desktopMaxContextLines = 80;

  /// Limite assoluto delle righe web.
  static const int _webMaxContextLines = 40;

  /// Minimo contesto che può essere richiesto da un profilo.
  static const int _minimumContextSizeFloor = 256;

  /*
   * ---------------------------------------------------------------------------
   * SAFE AUTOMATIC LIMITS
   * ---------------------------------------------------------------------------
   *
   * Questi valori sono volutamente separati dai limiti generali dei profili.
   *
   * Il motivo è importante:
   *
   * - PERFORMANCE può continuare a esistere per hardware più potente;
   * - AUTOMATIC deve invece essere sicuro sul dispositivo attuale;
   * - non vogliamo eliminare la possibilità futura di utilizzare finestre
   *   più grandi;
   * - non vogliamo obbligare tutti i modelli futuri a usare la stessa finestra.
   *
   * Il profilo automatico viene quindi scelto in base alla famiglia/taglia
   * del modello.
   */

  /// Contesto prudenziale per modelli mobile/small.
  static const int _automaticCompactMaxTotalSize = 3072;

  /// Contesto prudenziale per modelli medi.
  ///
  /// 3584 caratteri ≈ 896 token.
  ///
  /// Lascia margine a system prompt, prompt corrente e generazione.
  static const int _automaticStandardMaxTotalSize = 3584;

  /// Legacy character-size metadata for larger AUTOMATIC profiles.
  ///
  /// The Android conversational path no longer uses this value as the model
  /// capacity authority; exact GGUF tokens decide the final prompt window.
  static const int _automaticLargeMaxTotalSize = 4096;

  final MemoryWindowProfile profile;
  final MemoryWindowProfile activeProfile;

  final int maxContextLines;

  /// Maximum chronological candidate window that AUTOMATIC may expose when
  /// the user explicitly refers to earlier conversation state. Manual profiles
  /// keep this equal to [maxContextLines].
  final int maxContinuityContextLines;

  final int maxTotalSize;
  final int minContextSize;

  bool get isAutomatic =>
      profile == MemoryWindowProfile.automatic;

  bool get isCustom =>
      profile == MemoryWindowProfile.custom;

  bool get isWebSafe =>
      maxTotalSize <= _webMaxTotalSize;

  factory MemoryWindowConfig.automatic({
    String? modelId,
    bool isWeb = kIsWeb,
  }) {
    final activeProfile = _profileForModelId(modelId);

    /*
     * AUTOMATIC è speciale:
     *
     * non usiamo semplicemente _fromProfile(), perché vogliamo applicare
     * limiti conservativi compatibili con l'attuale runtime Android.
     */
    return _fromAutomaticProfile(
      activeProfile: activeProfile,
      isWeb: isWeb,
    );
  }

  factory MemoryWindowConfig.compact({
    bool isWeb = kIsWeb,
  }) {
    return _fromProfile(
      profile: MemoryWindowProfile.compact,
      activeProfile: MemoryWindowProfile.compact,
      isWeb: isWeb,
    );
  }

  factory MemoryWindowConfig.standard({
    bool isWeb = kIsWeb,
  }) {
    return _fromProfile(
      profile: MemoryWindowProfile.standard,
      activeProfile: MemoryWindowProfile.standard,
      isWeb: isWeb,
    );
  }

  factory MemoryWindowConfig.performance({
    bool isWeb = kIsWeb,
  }) {
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
      max: isWeb
          ? _webMaxContextLines
          : _desktopMaxContextLines,
    );

    final normalizedMaxTotalSize = _clamp(
      maxTotalSize,
      min: 512,
      max: isWeb
          ? _webMaxTotalSize
          : _desktopMaxTotalSize,
    );

    final normalizedMinContextSize =
        minContextSize != null
            ? _clamp(
                minContextSize,
                min: 32,
                max: normalizedMaxTotalSize,
              )
            : _clamp(
                _defaultMinContextSize(
                  normalizedMaxTotalSize,
                ),
                min: _minimumContextSizeFloor,
                max: normalizedMaxTotalSize,
              );

    return MemoryWindowConfig._(
      profile: MemoryWindowProfile.custom,
      activeProfile: MemoryWindowProfile.custom,
      maxContextLines: normalizedMaxContextLines,
      maxContinuityContextLines: normalizedMaxContextLines,
      maxTotalSize: normalizedMaxTotalSize,
      minContextSize: normalizedMinContextSize,
    );
  }

  static MemoryWindowConfig _fromProfile({
    required MemoryWindowProfile profile,
    required MemoryWindowProfile activeProfile,
    required bool isWeb,
  }) {
    final preset = _presetFor(
      activeProfile,
      isWeb: isWeb,
    );

    return MemoryWindowConfig._(
      profile: profile,
      activeProfile: activeProfile,
      maxContextLines: preset.$1,
      maxContinuityContextLines: preset.$1,
      maxTotalSize: preset.$2,
      minContextSize: preset.$3,
    );
  }

  /*
   * Profilo AUTOMATICO.
   *
   * Qui applichiamo il comportamento realmente desiderato:
   *
   *   1B / 1.5B / 2B / Phi
   *       -> compact
   *
   *   3B / 4B / modelli medi
   *       -> standard
   *
   *   7B / 8B / 9B+
   *       -> large automatic, ma con finestra prudente
   *
   * Il nome del profilo pubblico resta STANDARD/PERFORMANCE dove
   * necessario per compatibilità con l'architettura esistente.
   */
  static MemoryWindowConfig _fromAutomaticProfile({
    required MemoryWindowProfile activeProfile,
    required bool isWeb,
  }) {
    final maxContextLines = switch (activeProfile) {
      MemoryWindowProfile.compact =>
        isWeb ? 16 : 24,

      MemoryWindowProfile.standard =>
        isWeb ? 32 : 40,

      MemoryWindowProfile.performance =>
        isWeb ? 40 : 48,

      MemoryWindowProfile.custom =>
        isWeb ? 32 : 40,

      MemoryWindowProfile.automatic =>
        isWeb ? 32 : 40,
    };

    final maxTotalSize = switch (activeProfile) {
      MemoryWindowProfile.compact =>
        _automaticCompactMaxTotalSize,

      MemoryWindowProfile.standard =>
        isWeb
            ? _webMaxTotalSize
            : _automaticStandardMaxTotalSize,

      MemoryWindowProfile.performance =>
        isWeb
            ? _webMaxTotalSize
            : _automaticLargeMaxTotalSize,

      MemoryWindowProfile.custom =>
        isWeb
            ? _webMaxTotalSize
            : _automaticStandardMaxTotalSize,

      MemoryWindowProfile.automatic =>
        isWeb
            ? _webMaxTotalSize
            : _automaticStandardMaxTotalSize,
    };

    final minContextSize = switch (activeProfile) {
      MemoryWindowProfile.compact => 256,

      MemoryWindowProfile.standard => 384,

      MemoryWindowProfile.performance => 512,

      MemoryWindowProfile.custom => 384,

      MemoryWindowProfile.automatic => 384,
    };

    return MemoryWindowConfig._(
      profile: MemoryWindowProfile.automatic,
      activeProfile: activeProfile,
      maxContextLines: maxContextLines,
      // Keep ordinary prompts on the latency-friendly model-family window.
      // Deep conversational references may expose more chronology on non-web
      // runtimes; the selected backend still owns its final capacity bound.
      maxContinuityContextLines:
          isWeb ? maxContextLines : _desktopMaxContextLines,
      maxTotalSize: maxTotalSize,
      minContextSize: minContextSize,
    );
  }

  static (int, int, int) _presetFor(
    MemoryWindowProfile profile, {
    required bool isWeb,
  }) {
    switch (profile) {
      case MemoryWindowProfile.compact:
        return (
          isWeb ? 16 : 24,
          3072,
          256,
        );

      case MemoryWindowProfile.standard:
        return (
          isWeb ? 32 : 48,
          isWeb
              ? _webMaxTotalSize
              : 4608,
          512,
        );

      case MemoryWindowProfile.performance:
        return (
          isWeb ? 40 : 64,
          isWeb
              ? _webMaxTotalSize
              : _desktopMaxTotalSize,
          isWeb ? 512 : 768,
        );

      case MemoryWindowProfile.custom:
      case MemoryWindowProfile.automatic:
        return _presetFor(
          MemoryWindowProfile.standard,
          isWeb: isWeb,
        );
    }
  }

  static MemoryWindowProfile _profileForModelId(
    String? modelId,
  ) {
    final normalized =
        (modelId ?? '').trim().toLowerCase();

    if (normalized.isEmpty) {
      return MemoryWindowProfile.standard;
    }

    /*
     * -------------------------------------------------------------------------
     * SMALL / MOBILE
     * -------------------------------------------------------------------------
     */

    if (_containsAny(
      normalized,
      const <String>[
        '1b',
        '1_5b',
        '1.5b',
        '1_7b',
        '1.7b',
        '1_8b',
        '1.8b',
        '2b',
        'tiny',
        'tinyllama',
        'small',
        'smollm',
        'phi',
        'phi3',
        'phi-3',
        'phi3.5',
        'phi3_5',
        'gemma2b',
      ],
    )) {
      return MemoryWindowProfile.compact;
    }

    /*
     * -------------------------------------------------------------------------
     * LARGE / HEAVIER MODELS
     * -------------------------------------------------------------------------
     *
     * L'activeProfile resta PERFORMANCE per mantenere la semantica esistente,
     * ma AUTOMATIC applica il limite prudenziale di 4096 caratteri.
     */
    if (_containsAny(
      normalized,
      const <String>[
        '7b',
        '8b',
        '9b',
        '13b',
        '14b',
        '12b',
        'qwen3',
        'deepseek',
        'mistral',
        'mixtral',
        'performance',
      ],
    )) {
      return MemoryWindowProfile.performance;
    }

    /*
     * Modelli intermedi.
     */
    if (_containsAny(
      normalized,
      const <String>[
        '3b',
        '3.8b',
        '4b',
        '4.1b',
        '4.5b',
        '5b',
        '6b',
      ],
    )) {
      return MemoryWindowProfile.standard;
    }

    return MemoryWindowProfile.standard;
  }

  static bool _containsAny(
    String value,
    List<String> needles,
  ) {
    for (final needle in needles) {
      if (value.contains(needle)) {
        return true;
      }
    }

    return false;
  }

  static int _defaultMinContextSize(
    int maxTotalSize,
  ) {
    final derived = maxTotalSize ~/ 8;

    if (derived < _minimumContextSizeFloor) {
      return _minimumContextSizeFloor;
    }

    if (derived > 1024) {
      return 1024;
    }

    return derived;
  }

  static int _clamp(
    int value, {
    required int min,
    required int max,
  }) {
    if (value < min) {
      return min;
    }

    if (value > max) {
      return max;
    }

    return value;
  }
}
