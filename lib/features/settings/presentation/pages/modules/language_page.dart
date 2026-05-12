import 'package:flutter/material.dart';
import 'package:ai_orchestrator/core/config/runtime/language_config.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/language_service.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

class LanguagePage extends StatefulWidget {
  const LanguagePage({super.key});

  @override
  State<LanguagePage> createState() => _LanguagePageState();
}

class _LanguagePageState extends State<LanguagePage> {
  late String _language;

  @override
  void initState() {
    super.initState();
    _language = di.sl<LanguageService>().selectedLanguage;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final languageService = di.sl<LanguageService>();

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          l10n.t('language'),
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w500),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
        children: [
          DropdownButtonFormField<String>(
            value: _language,
            dropdownColor: const Color(0xFF1A1A1A),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: l10n.t('language'),
              filled: true,
              fillColor: const Color(0xFF151515),
            ),
            items: [
              DropdownMenuItem(
                value: LanguageConfig.system,
                child: Text(l10n.t('system_default')),
              ),
              DropdownMenuItem(value: 'en', child: Text(l10n.t('english'))),
              DropdownMenuItem(value: 'fr', child: Text(l10n.t('french'))),
              DropdownMenuItem(value: 'it', child: Text(l10n.t('italian'))),
              DropdownMenuItem(value: 'es', child: Text(l10n.t('spanish'))),
              DropdownMenuItem(value: 'de', child: Text(l10n.t('german'))),
            ],
            onChanged: (value) async {
              if (value == null) return;
              final messenger = ScaffoldMessenger.maybeOf(context);
              final settingsSaveFailedText = l10n.t('settings_save_failed');
              try {
                await languageService.setLanguage(value);
                if (!mounted) return;
                setState(() => _language = value);
              } catch (_) {
                if (!mounted) return;
                messenger?.showSnackBar(
                  SnackBar(content: Text(settingsSaveFailedText)),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
