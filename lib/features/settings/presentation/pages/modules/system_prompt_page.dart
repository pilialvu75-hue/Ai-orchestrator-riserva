import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/config/ai/system_prompt_config.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';

class SystemPromptPage extends StatefulWidget {
  const SystemPromptPage({super.key});

  @override
  State<SystemPromptPage> createState() => _SystemPromptPageState();
}

class _SystemPromptPageState extends State<SystemPromptPage> {
  static const _defaultPrompt = SystemPromptConfig.defaultPrompt;

  final _promptController = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _promptController.text =
        prefs.getString(AppConstants.prefDirectionalPrompt) ?? _defaultPrompt;
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        AppConstants.prefDirectionalPrompt, _promptController.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.t('settings_saved'))),
    );
  }

  Future<void> _resetDefault() async {
    setState(() => _promptController.text = _defaultPrompt);
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          l10n.t('system_prompt'),
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w500),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF8AB4F8)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
              children: [
                TextField(
                  controller: _promptController,
                  maxLines: 8,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: l10n.t('define_global_ai_behavior'),
                    filled: true,
                    fillColor: const Color(0xFF151515),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          const BorderSide(color: Colors.white12),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          const BorderSide(color: Colors.white12),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _resetDefault,
                      child: Text(l10n.t('reset_default')),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _save,
                      child: Text(l10n.t('save')),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
