import 'package:flutter/material.dart';

class LanguageConfig {
  const LanguageConfig({
    required this.supportedLanguages,
    required this.selectedLanguage,
    required this.fallbackLanguage,
  });

  final List<Locale> supportedLanguages;
  final String selectedLanguage;
  final Locale fallbackLanguage;

  static const String system = 'system';

  static const List<Locale> defaultSupportedLanguages = <Locale>[
    Locale('en'),
    Locale('fr'),
    Locale('it'),
    Locale('es'),
    Locale('de'),
  ];

  static bool isSupportedCode(String code) {
    return defaultSupportedLanguages.any((locale) => locale.languageCode == code);
  }

  static Locale fallbackFromSystem(Locale systemLocale) {
    return defaultSupportedLanguages.firstWhere(
      (locale) => locale.languageCode == systemLocale.languageCode,
      orElse: () => defaultSupportedLanguages.first,
    );
  }

  static Locale resolveLocale({
    required String selectedLanguage,
    required Locale systemLocale,
  }) {
    if (selectedLanguage == system) {
      return fallbackFromSystem(systemLocale);
    }

    return defaultSupportedLanguages.firstWhere(
      (locale) => locale.languageCode == selectedLanguage,
      orElse: () => fallbackFromSystem(systemLocale),
    );
  }
}
