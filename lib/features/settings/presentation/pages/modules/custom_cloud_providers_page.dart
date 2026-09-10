import 'package:flutter/material.dart';

import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/custom_cloud_provider_store.dart';

class CustomCloudProvidersPage extends StatefulWidget {
  const CustomCloudProvidersPage({super.key});

  @override
  State<CustomCloudProvidersPage> createState() =>
      _CustomCloudProvidersPageState();
}

class _CustomCloudProvidersPageState extends State<CustomCloudProvidersPage> {
  final CustomCloudProviderStore _store = CustomCloudProviderStore.instance;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final profiles = _store.profiles;
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        foregroundColor: Colors.white,
        title: const Text('Custom Cloud providers'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('Add provider'),
      ),
      body: profiles.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No custom providers yet. Add a compatible API once and it '
                'will appear in the normal Cloud provider selectors without '
                'requiring another app build.',
                style: TextStyle(color: Colors.white70, height: 1.45),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: profiles.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final profile = profiles[index];
                return Card(
                  color: const Color(0xFF1F1F1F),
                  child: ListTile(
                    title: Text(
                      profile.displayName,
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      '${_store.billingLabel(profile.billing)} • '
                      '${_store.protocolLabel(profile.protocol)}\n'
                      '${profile.defaultModel}\n${profile.endpoint}',
                      style: const TextStyle(color: Colors.white60, height: 1.35),
                    ),
                    isThreeLine: true,
                    onTap: _busy ? null : () => _openEditor(existing: profile),
                    trailing: IconButton(
                      tooltip: 'Remove provider',
                      onPressed: _busy ? null : () => _remove(profile),
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _openEditor({CustomCloudProviderProfile? existing}) async {
    final nameController = TextEditingController(text: existing?.displayName ?? '');
    final endpointController = TextEditingController(text: existing?.endpoint ?? '');
    final modelController = TextEditingController(text: existing?.defaultModel ?? '');
    final apiKeyController = TextEditingController();
    var protocol = existing?.protocol ??
        CustomCloudProviderProtocol.openAiCompatible;
    var billing = existing?.billing ?? CustomCloudProviderBilling.free;
    var obscureSecret = true;

    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F1F1F),
              title: Text(
                existing == null ? 'Add Cloud provider' : 'Edit Cloud provider',
                style: const TextStyle(color: Colors.white),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _field(nameController, 'Provider name'),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<CustomCloudProviderBilling>(
                      value: billing,
                      dropdownColor: const Color(0xFF262626),
                      decoration: const InputDecoration(
                        labelText: 'Cost',
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(color: Colors.white),
                      items: CustomCloudProviderBilling.values
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(_store.billingLabel(value)),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => billing = value);
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Choose Free only when this API route is known to be free. '
                      'Paid providers remain protected by the spending policy.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<CustomCloudProviderProtocol>(
                      value: protocol,
                      dropdownColor: const Color(0xFF262626),
                      decoration: const InputDecoration(
                        labelText: 'API compatibility',
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(color: Colors.white),
                      items: CustomCloudProviderProtocol.values
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(_store.protocolLabel(value)),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => protocol = value);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    _field(
                      endpointController,
                      protocol == CustomCloudProviderProtocol.geminiCompatible
                          ? 'Endpoint URL (may contain {model})'
                          : 'Exact API endpoint URL',
                    ),
                    const SizedBox(height: 12),
                    _field(modelController, 'Default model'),
                    const SizedBox(height: 12),
                    TextField(
                      controller: apiKeyController,
                      obscureText: obscureSecret,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: existing == null
                            ? 'API key'
                            : 'New API key (optional)',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          onPressed: () => setDialogState(
                            () => obscureSecret = !obscureSecret,
                          ),
                          icon: Icon(
                            obscureSecret
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (save != true || !mounted) {
      nameController.dispose();
      endpointController.dispose();
      modelController.dispose();
      apiKeyController.dispose();
      return;
    }

    setState(() => _busy = true);
    try {
      CustomCloudProviderProfile profile;
      if (existing == null) {
        profile = await _store.create(
          displayName: nameController.text,
          endpoint: endpointController.text,
          defaultModel: modelController.text,
          protocol: protocol,
          billing: billing,
        );
      } else {
        profile = CustomCloudProviderProfile(
          id: existing.id,
          displayName: nameController.text,
          endpoint: endpointController.text,
          defaultModel: modelController.text,
          protocol: protocol,
          billing: billing,
        );
        await _store.update(profile);
      }

      final apiKey = apiKeyController.text.trim();
      if (apiKey.isNotEmpty) {
        await CloudCredentialStore.instance.setApiKey(profile.id, apiKey);
      }
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Custom provider error: $error')),
        );
      }
    } finally {
      nameController.dispose();
      endpointController.dispose();
      modelController.dispose();
      apiKeyController.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(CustomCloudProviderProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove provider?'),
        content: Text(
          '${profile.displayName} and its stored credential will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      // Remove the encrypted secret first while the dynamic catalog still
      // recognizes the provider ID.
      await CloudCredentialStore.instance.remove(profile.id);
      await _store.remove(profile.id);
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      autocorrect: false,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
