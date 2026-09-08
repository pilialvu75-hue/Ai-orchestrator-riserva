import 'package:flutter/material.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';

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
  final CloudCredentialStore _credentialStore = CloudCredentialStore.instance;
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _budgetController = TextEditingController();

  AiRuntimeMode _runtimeMode = AiRuntimeMode.hybrid;
  CloudSpendingMode _spendingMode = CloudSpendingMode.confirmBeforeSpending;
  String _provider = 'openAi';
  bool _loading = true;
  bool _saving = false;
  bool _obscureSecret = true;

  @override
  void initState() {
    super.initState();
    _settingsService = widget.settingsService;
    _loadPrefs();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _modelController.dispose();
    _budgetController.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final provider = _settingsService.activeProvider;
    final budget = _settingsService.cloudBudgetLimit;

    if (!mounted) return;
    setState(() {
      _runtimeMode = _settingsService.runtimeMode;
      _provider = provider;
      _spendingMode = _settingsService.cloudSpendingMode;
      _modelController.text = _settingsService.cloudModelFor(provider);
      _budgetController.text = budget?.toString() ?? '';
      _loading = false;
    });
  }

  void _selectProvider(String provider) {
    setState(() {
      _provider = provider;
      _apiKeyController.clear();
      _modelController.text = _settingsService.cloudModelFor(provider);
      _obscureSecret = true;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    try {
      await _settingsService.setRuntimeMode(_runtimeMode);
      await _settingsService.setActiveProvider(_provider);
      await _settingsService.setCloudModel(
        _provider,
        _modelController.text,
      );
      await _settingsService.setCloudSpendingMode(_spendingMode);

      final budget = double.tryParse(
        _budgetController.text.trim().replaceAll(',', '.'),
      );
      await _settingsService.setCloudBudgetLimit(budget);

      final secret = _apiKeyController.text.trim();
      if (secret.isNotEmpty) {
        await _credentialStore.setApiKey(_provider, secret);
        _apiKeyController.clear();
      }

      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.t('settings_saved'))),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cloud settings error: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _removeCredential() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _credentialStore.remove(_provider);
      _apiKeyController.clear();
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  CloudCredentialSnapshot get _credential =>
      _credentialStore.snapshotFor(_provider);

  CloudProviderDefinition get _definition =>
      CloudProviderCatalog.definitionFor(_provider)!;

  String _spendingLabel(CloudSpendingMode mode) {
    switch (mode) {
      case CloudSpendingMode.freeOnly:
        return 'Free only';
      case CloudSpendingMode.prepaidOnly:
        return 'Prepaid only';
      case CloudSpendingMode.budgetLimit:
        return 'Budget limit';
      case CloudSpendingMode.confirmBeforeSpending:
        return 'Confirm before spending';
      case CloudSpendingMode.unrestricted:
        return 'Allow automatic paid requests';
    }
  }

  String _credentialStatusText() {
    final snapshot = _credential;
    if (!snapshot.configured) return 'Not configured';
    if (snapshot.isExpired) return 'Credential expired';
    if (snapshot.fromEnvironmentFallback) return 'Configured by environment';
    if (snapshot.kind == CloudCredentialKind.oauthAccessToken) {
      return 'OAuth connected';
    }
    return 'API key stored securely';
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
            color: Colors.white,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF8AB4F8)),
            )
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
                const SizedBox(height: 28),
                const _SectionTitle('Cloud providers'),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: _provider,
                  dropdownColor: const Color(0xFF1F1F1F),
                  decoration: const InputDecoration(
                    labelText: 'Preferred provider',
                    labelStyle: TextStyle(color: Colors.white70),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: Colors.white),
                  items: CloudProviderCatalog.supportedProviders
                      .map(
                        (provider) => DropdownMenuItem<String>(
                          value: provider,
                          child: Text(
                            CloudProviderCatalog.definitionFor(provider)!
                                .displayName,
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value != null) _selectProvider(value);
                        },
                ),
                const SizedBox(height: 12),
                _StatusRow(
                  label: _credentialStatusText(),
                  positive: _credential.configured && !_credential.isExpired,
                ),
                if (_definition.supportsOAuth) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'OAuth is supported by this provider. API key/BYOK remains '
                    'available until an OAuth client is configured for this app.',
                    style: TextStyle(color: Colors.white54, height: 1.35),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _apiKeyController,
                  obscureText: _obscureSecret,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'New API key / credential',
                    helperText: _credential.configured
                        ? 'Leave blank to keep the stored credential.'
                        : 'Saved in encrypted device storage.',
                    helperStyle: const TextStyle(color: Colors.white54),
                    labelStyle: const TextStyle(color: Colors.white70),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      onPressed: () =>
                          setState(() => _obscureSecret = !_obscureSecret),
                      icon: Icon(
                        _obscureSecret ? Icons.visibility : Icons.visibility_off,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ),
                if (_credential.configured) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _saving ? null : _removeCredential,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove stored credential'),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _modelController,
                  autocorrect: false,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Model',
                    helperText: 'Default: ${_definition.defaultModel}',
                    helperStyle: const TextStyle(color: Colors.white54),
                    labelStyle: const TextStyle(color: Colors.white70),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 28),
                const _SectionTitle('Spending policy'),
                const SizedBox(height: 10),
                DropdownButtonFormField<CloudSpendingMode>(
                  value: _spendingMode,
                  dropdownColor: const Color(0xFF1F1F1F),
                  decoration: const InputDecoration(
                    labelText: 'Cloud spending',
                    labelStyle: TextStyle(color: Colors.white70),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: Colors.white),
                  items: CloudSpendingMode.values
                      .map(
                        (mode) => DropdownMenuItem<CloudSpendingMode>(
                          value: mode,
                          child: Text(_spendingLabel(mode)),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value != null) {
                            setState(() => _spendingMode = value);
                          }
                        },
                ),
                if (_spendingMode == CloudSpendingMode.budgetLimit) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _budgetController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Budget limit',
                      labelStyle: TextStyle(color: Colors.white70),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  _spendingMode == CloudSpendingMode.unrestricted
                      ? 'Automatic Cloud requests are enabled. Provider charges '
                          'can apply according to your provider account.'
                      : 'Automatic paid Cloud requests stay blocked until the '
                          'selected policy can be verified. Local fallback remains available.',
                  style: TextStyle(
                    color: _spendingMode == CloudSpendingMode.unrestricted
                        ? Colors.orangeAccent
                        : Colors.white54,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(l10n.t('save')),
                  ),
                ),
              ],
            ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.positive});

  final String label;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          positive ? Icons.check_circle_outline : Icons.info_outline,
          color: positive ? Colors.greenAccent : Colors.white54,
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      ],
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
        color: selected ? const Color(0xFF8AB4F8) : Colors.white24,
      ),
    );
  }
}
