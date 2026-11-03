import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:flutter/material.dart';

/// Settings view for stored Cloud disclosure rules.
///
/// Normal Settings currently has NO trusted owner/session principal: this
/// screen displays a non-operational status until a verified authenticated
/// caller explicitly supplies [manager], [ownerId] and [sessionId].
/// Synthetic widget tests inject a real in-memory consent manager.
/// Opening Settings never creates a profile, sends data or grants consent.
class HybridCloudConsentSettingsPage extends StatefulWidget {
  const HybridCloudConsentSettingsPage({
    super.key,
    this.manager,
    this.ownerId,
    this.sessionId,
    this.credentials,
  });

  final HybridCloudDisclosureConsent? manager;
  final String? ownerId;
  final String? sessionId;
  final CloudCredentialStore? credentials;

  @override
  State<HybridCloudConsentSettingsPage> createState() =>
      _HybridCloudConsentSettingsPageState();
}

enum _EditChoice { ask, allow, deny, clear }

class _HybridCloudConsentSettingsPageState
    extends State<HybridCloudConsentSettingsPage> {
  String? _provider;
  String? _account;
  bool _loading = false;
  bool _busy = false;
  bool _failed = false;
  Map<HybridDisclosureScope, HybridCloudStoredConsent> _rules =
      const <HybridDisclosureScope, HybridCloudStoredConsent>{};

  String _tr(String key) => context.l10n.t('cloud_permission_' + key);

  bool get _hasContext =>
      widget.manager != null &&
      (widget.ownerId?.trim().isNotEmpty ?? false) &&
      (widget.sessionId?.trim().isNotEmpty ?? false);

  CloudCredentialStore get _credentials =>
      widget.credentials ?? CloudCredentialStore.instance;

  List<CloudCredentialSnapshot> get _accounts =>
      _credentials.snapshots.where((s) => s.configured &&
          !s.isExpired && !s.fromEnvironmentFallback &&
          (s.accountId?.isNotEmpty ?? false)).toList(growable: false);

  @override
  void initState() {
    super.initState();
    if (_hasContext) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
  }

  Future<void> _refresh() async {
    if (!_hasContext || _busy || !mounted) return;
    final accounts = _accounts;
    final provider = accounts.any((a) => a.providerId == _provider)
        ? _provider : (accounts.isEmpty ? null : accounts.first.providerId);
    final account = provider == null
        ? null : _credentials.snapshotFor(provider).accountId;
    setState(() {
      _provider = provider;
      _account = account;
      _loading = true;
      _failed = false;
      _rules = const <HybridDisclosureScope, HybridCloudStoredConsent>{};
    });
    try {
      if (provider != null && account != null) {
        final loaded = await widget.manager!.listStoredPreferences(
          ownerId: widget.ownerId!,
          sessionId: widget.sessionId!,
          providerId: provider,
          accountId: account,
        );
        if (mounted && _provider == provider && _account == account) {
          setState(() => _rules = loaded);
        }
      }
    } on Object catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _name(HybridDisclosureScope scope) =>
      _tr('origin_' + scope.origin.name) +
      ' · ' + _tr('level_' + scope.sensitivity.name);

  String _rule(HybridCloudStoredConsent rule) => switch (rule) {
        HybridCloudStoredConsent.allowAlways => _tr('allow'),
        HybridCloudStoredConsent.askEveryTime => _tr('ask'),
        HybridCloudStoredConsent.neverShare => _tr('deny'),
      };

  Future<void> _edit([HybridDisclosureScope? existing]) async {
    if (!_hasContext || _loading || _busy ||
        _provider == null || _account == null) return;
    var origin = existing?.origin ?? HybridDisclosureOrigin.durableMemory;
    var level = existing?.sensitivity ??
        HybridDisclosureSensitivity.preference;
    var choice = _EditChoice.ask;

    final answer = await showDialog<
        (HybridDisclosureScope, _EditChoice)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title: Text(_tr('change')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<HybridDisclosureOrigin>(
                key: const Key('consent-origin'),
                isExpanded: true,
                value: origin,
                decoration: InputDecoration(labelText: _tr('origin')),
                items: HybridDisclosureOrigin.values.map((item) =>
                    DropdownMenuItem(
                      value: item,
                      child: Text(_tr('origin_' + item.name)),
                    )).toList(),
                onChanged: existing == null
                    ? (value) {
                        if (value != null) setDialog(() => origin = value);
                      }
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<HybridDisclosureSensitivity>(
                key: const Key('consent-level'),
                isExpanded: true,
                value: level,
                decoration: InputDecoration(labelText: _tr('level')),
                items: HybridDisclosureSensitivity.values.map((item) =>
                    DropdownMenuItem(
                      value: item,
                      child: Text(_tr('level_' + item.name)),
                    )).toList(),
                onChanged: existing == null
                    ? (value) {
                        if (value != null) setDialog(() {
                          level = value;
                          if (level == HybridDisclosureSensitivity.unknown &&
                              choice == _EditChoice.allow) {
                            choice = _EditChoice.ask;
                          }
                        });
                      }
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<_EditChoice>(
                key: const Key('consent-choice'),
                isExpanded: true,
                value: choice,
                decoration: InputDecoration(labelText: _tr('choice')),
                items: _EditChoice.values.where((item) =>
                    item != _EditChoice.allow ||
                    level != HybridDisclosureSensitivity.unknown)
                    .map((item) => DropdownMenuItem(
                      value: item,
                      child: Text(switch (item) {
                        _EditChoice.ask => _tr('ask'),
                        _EditChoice.allow => _tr('allow'),
                        _EditChoice.deny => _tr('deny'),
                        _EditChoice.clear => _tr('clear'),
                      }),
                    )).toList(),
                onChanged: (value) {
                  if (value != null) setDialog(() => choice = value);
                },
              ),
              const SizedBox(height: 12),
              Text(_tr('once'), style:
                  Theme.of(dialogContext).textTheme.bodySmall),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(_tr('cancel')),
            ),
            FilledButton(
              key: const Key('consent-apply'),
              onPressed: () => Navigator.pop(
                dialogContext,
                (HybridDisclosureScope(origin, level), choice),
              ),
              child: Text(_tr('continue')),
            ),
          ],
        ),
      ),
    );
    if (answer == null || !mounted) return;
    final scope = answer.$1;
    final action = answer.$2;
    if (action == _EditChoice.allow) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(_tr('confirm_title')),
          content: Text(_tr('confirm_body')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(_tr('cancel'))),
            FilledButton(
              key: const Key('consent-confirm-allow'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(_tr('confirm')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    final provider = _provider!;
    final account = _account!;
    final rule = switch (action) {
      _EditChoice.ask => HybridCloudStoredConsent.askEveryTime,
      _EditChoice.allow => HybridCloudStoredConsent.allowAlways,
      _EditChoice.deny => HybridCloudStoredConsent.neverShare,
      _EditChoice.clear => null,
    };
    setState(() => _busy = true);
    try {
      await widget.manager!.setStoredPreference(
        ownerId: widget.ownerId!,
        sessionId: widget.sessionId!,
        providerId: provider,
        accountId: account,
        scope: scope,
        preference: rule,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await _refresh();
      if (mounted && !_failed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr('saved'))),
        );
      }
    } on Object catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr('failed'))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    return Scaffold(
      appBar: AppBar(title: Text(_tr('title'))),
      body: ListView(
        key: const Key('cloud-consent-settings'),
        padding: const EdgeInsets.all(16),
        children: [
          Text(_tr('intro')),
          const SizedBox(height: 16),
          if (!_hasContext) ...[
            const Icon(Icons.shield_outlined, size: 36),
            const SizedBox(height: 12),
            Text(_tr('inactive'), key: const Key('consent-inactive')),
            const SizedBox(height: 12),
            Text(_tr('local_note')),
          ] else if (accounts.isEmpty)
            Text(_tr('no_account'), key: const Key('consent-no-account'))
          else ...[
            DropdownButtonFormField<String>(
              key: const Key('consent-provider'),
              isExpanded: true,
              value: _provider != null &&
                      accounts.any((a) => a.providerId == _provider)
                  ? _provider : accounts.first.providerId,
              decoration: InputDecoration(labelText: _tr('provider')),
              items: accounts.map((a) => DropdownMenuItem<String>(
                value: a.providerId,
                child: Text(CloudProviderCatalog
                    .definitionFor(a.providerId)?.displayName ?? a.providerId),
              )).toList(),
              onChanged: _busy ? null : (value) {
                if (value == null) return;
                setState(() {
                  _provider = value;
                  _account = _credentials.snapshotFor(value).accountId;
                  _rules = const <HybridDisclosureScope,
                      HybridCloudStoredConsent>{};
                });
                _refresh();
              },
            ),
            const SizedBox(height: 14),
            Text(_tr('account_note')),
            if (_loading) const Center(child: CircularProgressIndicator()),
            if (_failed) Text(_tr('failed'), key: const Key('consent-failed')),
            if (!_loading && !_failed && _rules.isEmpty)
              Text(_tr('empty'), key: const Key('consent-empty')),
            for (final item in _rules.entries)
              Card(child: ListTile(
                title: Text(_name(item.key)),
                subtitle: Text(_rule(item.value)),
                trailing: IconButton(
                  key: Key('consent-edit-' + item.key.origin.name +
                      '-' + item.key.sensitivity.name),
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: _tr('edit'),
                  onPressed: _busy ? null : () => _edit(item.key),
                ),
              )),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('consent-add'),
              onPressed: _busy || _loading || _failed ? null : () => _edit(),
              icon: const Icon(Icons.add),
              label: Text(_tr('add')),
            ),
          ],
          const SizedBox(height: 22),
          Text(_tr('footer'),
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
