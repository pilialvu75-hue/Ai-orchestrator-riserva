import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';

class TokenConfiguratorPage extends StatefulWidget {
  const TokenConfiguratorPage({
    super.key,
    required this.settingsService,
    this.isWeb = kIsWeb,
  });

  final AiRuntimeSettingsService settingsService;
  final bool isWeb;

  @override
  State<TokenConfiguratorPage> createState() => _TokenConfiguratorPageState();
}

class _TokenConfiguratorPageState extends State<TokenConfiguratorPage> {
  late final AiRuntimeSettingsService _settingsService;
  late MemoryWindowProfile _profile;
  late int _customTokenBudget;
  late int _customLineBudget;

  @override
  void initState() {
    super.initState();
    _settingsService = widget.settingsService;
    _profile = _settingsService.memoryWindowProfile;
    _customTokenBudget = _settingsService.customMemoryTokenBudget;
    _customLineBudget = _settingsService.customMemoryLineBudget;
  }

  Future<void> _saveProfile(MemoryWindowProfile profile) async {
    setState(() => _profile = profile);
    await _settingsService.setMemoryWindowProfile(profile);
    if (!mounted) return;
    _showSavedSnackBar();
  }

  Future<void> _saveCustomBudget(double value) async {
    final next = value.round();
    setState(() => _customTokenBudget = next);
    await _settingsService.setMemoryWindowCustomSettings(
      tokenBudget: _customTokenBudget,
      lineBudget: _customLineBudget,
    );
  }

  Future<void> _saveCustomLines(double value) async {
    final next = value.round();
    setState(() => _customLineBudget = next);
    await _settingsService.setMemoryWindowCustomSettings(
      tokenBudget: _customTokenBudget,
      lineBudget: _customLineBudget,
    );
  }

  void _showSavedSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.t('settings_saved'))),
    );
  }

  MemoryWindowConfig _previewConfig() {
    switch (_profile) {
      case MemoryWindowProfile.automatic:
        return MemoryWindowConfig.automatic(
          modelId: _settingsService.selectedModelId,
          isWeb: widget.isWeb,
        );
      case MemoryWindowProfile.compact:
        return MemoryWindowConfig.compact(isWeb: widget.isWeb);
      case MemoryWindowProfile.standard:
        return MemoryWindowConfig.standard(isWeb: widget.isWeb);
      case MemoryWindowProfile.performance:
        return MemoryWindowConfig.performance(isWeb: widget.isWeb);
      case MemoryWindowProfile.custom:
        return MemoryWindowConfig.custom(
          maxContextLines: _customLineBudget,
          maxTotalSize: _customTokenBudget,
          isWeb: widget.isWeb,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final preview = _previewConfig();
    final displayBudget =
        widget.isWeb && _customTokenBudget > 8000 ? 8000 : _customTokenBudget;
    final displayLines =
        widget.isWeb && _customLineBudget > 80 ? 80 : _customLineBudget;
    final showWebWarning =
        widget.isWeb &&
        _profile == MemoryWindowProfile.custom &&
        _customTokenBudget > 8000;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          'Token Configurator',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
        children: [
          const Text(
            'Select a memory budget profile for chat context trimming.',
            style: TextStyle(color: Colors.white70, height: 1.4),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<MemoryWindowProfile>(
            value: _profile,
            dropdownColor: const Color(0xFF151515),
            decoration: const InputDecoration(
              labelText: 'Memory profile',
              labelStyle: TextStyle(color: Colors.white70),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white24),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF8AB4F8)),
              ),
            ),
            style: const TextStyle(color: Colors.white),
            items: const [
              DropdownMenuItem(
                value: MemoryWindowProfile.automatic,
                child: Text('Automatico'),
              ),
              DropdownMenuItem(
                value: MemoryWindowProfile.compact,
                child: Text('4K'),
              ),
              DropdownMenuItem(
                value: MemoryWindowProfile.standard,
                child: Text('8K'),
              ),
              DropdownMenuItem(
                value: MemoryWindowProfile.performance,
                child: Text('16K'),
              ),
              DropdownMenuItem(
                value: MemoryWindowProfile.custom,
                child: Text('Personalizzato'),
              ),
            ],
            onChanged: (value) {
              if (value == null) return;
              unawaited(_saveProfile(value));
            },
          ),
          const SizedBox(height: 16),
          _PreviewCard(preview: preview),
          if (showWebWarning) ...[
            const SizedBox(height: 12),
            const _WarningBanner(
              text:
                  'Web safety clamp: custom budgets above 8000 are reduced automatically.',
            ),
          ],
          if (_profile == MemoryWindowProfile.custom) ...[
            const SizedBox(height: 20),
            Text(
              'Token budget: $displayBudget',
              style: const TextStyle(color: Colors.white70),
            ),
            Slider(
              value: displayBudget.toDouble(),
              min: 2048,
              max: widget.isWeb ? 8000 : 16000,
              divisions: widget.isWeb ? 23 : 28,
              onChanged: (value) {
                unawaited(_saveCustomBudget(value));
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Context lines: $displayLines',
              style: const TextStyle(color: Colors.white70),
            ),
            Slider(
              value: displayLines.toDouble(),
              min: 16,
              max: widget.isWeb ? 80 : 120,
              divisions: widget.isWeb ? 64 : 104,
              onChanged: (value) {
                unawaited(_saveCustomLines(value));
              },
            ),
          ],
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _showSavedSnackBar,
              child: Text(l10n.t('save')),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.preview});

  final MemoryWindowConfig preview;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(
        'Active: ${preview.activeProfile.name} • lines ${preview.maxContextLines} • budget ${preview.maxTotalSize} • min ${preview.minContextSize}',
        style: const TextStyle(color: Colors.white70, height: 1.4),
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF3A2A00),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFF9A826).withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Color(0xFFFFD08A), height: 1.4),
      ),
    );
  }
}
