import 'package:flutter/material.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';

class AiModePage extends StatefulWidget {
  const AiModePage({
    super.key,
    required this.settingsService,
  });

  final AiRuntimeSettingsService settingsService;

  @override
  State<AiModePage> createState() => _AiModePageState();
}

class _AiModePageState extends State<AiModePage> {
  late final AiRuntimeSettingsService _settingsService;
  AiRuntimeMode _runtimeMode = AiRuntimeMode.hybrid;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _settingsService = widget.settingsService;
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    setState(() {
      _runtimeMode = _settingsService.runtimeMode;
      _loading = false;
    });
  }

  Future<void> _save() async {
    await _settingsService.setRuntimeMode(_runtimeMode);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.t('settings_saved'))),
    );
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
          l10n.t('ai_mode'),
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
                Text(
                  l10n.t('runtime_routing_description'),
                  style: const TextStyle(color: Colors.white70, height: 1.4),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ModeChip(
                      label: l10n.t('local_ai_mode'),
                      selected: _runtimeMode == AiRuntimeMode.local,
                      onTap: () =>
                          setState(() => _runtimeMode = AiRuntimeMode.local),
                    ),
                    _ModeChip(
                      label: l10n.t('cloud_ai_mode'),
                      selected: _runtimeMode == AiRuntimeMode.cloud,
                      onTap: () =>
                          setState(() => _runtimeMode = AiRuntimeMode.cloud),
                    ),
                    _ModeChip(
                      label: l10n.t('hybrid_ai_mode'),
                      selected: _runtimeMode == AiRuntimeMode.hybrid,
                      onTap: () =>
                          setState(() => _runtimeMode = AiRuntimeMode.hybrid),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _save,
                    child: Text(l10n.t('save')),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: const Color(0xFF8AB4F8).withValues(alpha: 0.25),
      labelStyle: TextStyle(
        color: selected ? const Color(0xFF8AB4F8) : Colors.white70,
      ),
      backgroundColor: const Color(0xFF1F1F1F),
      side: BorderSide(
          color: selected ? const Color(0xFF8AB4F8) : Colors.white24),
    );
  }
}
