import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/runtime/language_config.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';

class LanguageService extends ChangeNotifier {
  LanguageService({required ConfigRepository configRepository})
      : _configRepository = configRepository,
        _systemLocale = PlatformDispatcher.instance.locale,
        _config = LanguageConfig(
          supportedLanguages: LanguageConfig.defaultSupportedLanguages,
          selectedLanguage: LanguageConfig.system,
          fallbackLanguage: LanguageConfig.fallbackFromSystem(
            PlatformDispatcher.instance.locale,
          ),
        );

  final ConfigRepository _configRepository;

  Locale _systemLocale;
  LanguageConfig _config;

  LanguageConfig get config => _config;

  String get selectedLanguage => _config.selectedLanguage;

  Locale get currentLocale => LanguageConfig.resolveLocale(
        selectedLanguage: _config.selectedLanguage,
        systemLocale: _systemLocale,
      );

  Future<void> loadSavedLanguage() async {
    _systemLocale = PlatformDispatcher.instance.locale;
    final saved = _configRepository.getString(AppConstants.prefLanguageOverride);
    final selected = _normalizeSelection(saved);

    _config = LanguageConfig(
      supportedLanguages: LanguageConfig.defaultSupportedLanguages,
      selectedLanguage: selected,
      fallbackLanguage: LanguageConfig.fallbackFromSystem(_systemLocale),
    );
    notifyListeners();
  }

  Future<void> setLanguage(String language) async {
    final selected = _normalizeSelection(language);
    await _configRepository.setString(AppConstants.prefLanguageOverride, selected);

    _config = LanguageConfig(
      supportedLanguages: LanguageConfig.defaultSupportedLanguages,
      selectedLanguage: selected,
      fallbackLanguage: LanguageConfig.fallbackFromSystem(_systemLocale),
    );
    notifyListeners();
  }

  String _normalizeSelection(String? raw) {
    if (raw == null || raw.isEmpty || raw == LanguageConfig.system) {
      return LanguageConfig.system;
    }

    if (LanguageConfig.isSupportedCode(raw)) {
      return raw;
    }

    return LanguageConfig.system;
  }
}
