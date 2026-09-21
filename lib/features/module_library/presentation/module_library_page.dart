import 'dart:async';
import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_auth.dart';
import 'package:ai_orchestrator/features/module_library/data/module_curator_github_actions_source.dart';
import 'package:ai_orchestrator/features/module_library/data/module_library_github_config.dart';
import 'package:ai_orchestrator/features/module_library/data/module_library_status_repository.dart';
import 'package:ai_orchestrator/features/module_library/domain/module_capability_status.dart';
import 'package:ai_orchestrator/features/module_library/domain/module_curator_advice.dart';
import 'package:ai_orchestrator/features/module_library/presentation/module_curator_advice_dialog.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef ModuleCuratorRunner = Future<ModuleCuratorResult> Function({
  required ModuleCuratorTask task,
  String? capabilityId,
});

class ModuleLibraryPage extends StatefulWidget {
  const ModuleLibraryPage({
    super.key,
    this.repository,
    this.credentialStore,
    this.configStore,
    this.authClient,
    this.curatorRunner,
  });

  final ModuleLibraryStatusRepository? repository;
  final WorkshopLibraryGitHubCredentialStore? credentialStore;
  final ModuleLibraryGitHubConfigStore? configStore;
  final WorkshopLibraryGitHubAuthClient? authClient;
  final ModuleCuratorRunner? curatorRunner;

  @override
  State<ModuleLibraryPage> createState() => _ModuleLibraryPageState();
}

class _ModuleLibraryPageState extends State<ModuleLibraryPage> {
  late final ModuleLibraryStatusRepository _repository;
  late final WorkshopLibraryGitHubCredentialStore _credentialStore;
  late final ModuleLibraryGitHubConfigStore _configStore;
  late final WorkshopLibraryGitHubAuthClient _authClient;
  late final ModuleCuratorRunner _curatorRunner;
  late final bool _externalRepository;

  bool _loading = true;
  bool _connected = false;
  bool _healthLoading = false;
  String? _clientId;
  String? _error;
  final Set<String> _curatorLoading = <String>{};
  List<ModuleCapabilityStatus> _items = const <ModuleCapabilityStatus>[];
  DateTime? _lastUpdatedAt;

  @override
  void initState() {
    super.initState();
    _externalRepository = widget.repository != null;
    _credentialStore =
        widget.credentialStore ?? WorkshopLibraryGitHubCredentialStore();
    _configStore = widget.configStore ?? ModuleLibraryGitHubConfigStore();
    _authClient = widget.authClient ?? WorkshopLibraryGitHubAuthClient();
    _repository = widget.repository ??
        ModuleLibraryStatusRepository(
          credentialStore: _credentialStore,
          configStore: _configStore,
          authClient: _authClient,
        );
    _curatorRunner = widget.curatorRunner ??
        ModuleCuratorGitHubActionsSource(
          credentialStore: _credentialStore,
          configStore: _configStore,
          authClient: _authClient,
        ).run;
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (_externalRepository) {
      _connected = true;
      await _refresh();
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    final clientId = await _configStore.loadClientId();
    final credential = await _credentialStore.load();
    if (!mounted) return;
    setState(() {
      _clientId = clientId;
      _connected = credential != null;
      _loading = false;
    });
    if (credential != null) {
      await _refresh();
    }
  }

  Future<void> _refresh() async {
    if (!_externalRepository && !_connected) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _repository.load();
      if (!mounted) return;
      setState(() {
        _items = items;
        _lastUpdatedAt = DateTime.now();
        _connected = true;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      final text = error.toString();
      setState(() {
        _error = text;
        if (text.contains('assente o scaduta')) {
          _connected = false;
        }
        _loading = false;
      });
    }
  }

  Future<void> _runCuratorForCapability(ModuleCapabilityStatus status) async {
    final capabilityId = status.capabilityId;
    if (_curatorLoading.contains(capabilityId)) return;
    setState(() => _curatorLoading.add(capabilityId));
    try {
      final result = await _curatorRunner(
        task: ModuleCuratorTask.rankCandidates,
        capabilityId: capabilityId,
      );
      if (!mounted) return;
      await showModuleCuratorAdviceDialog(
        context,
        title: 'Consiglio AI — ${status.title}',
        result: result,
      );
    } catch (error) {
      if (!mounted) return;
      await showModuleCuratorErrorDialog(context, error);
    } finally {
      if (mounted) {
        setState(() => _curatorLoading.remove(capabilityId));
      }
    }
  }

  Future<void> _runHealthReview() async {
    if (_healthLoading) return;
    setState(() => _healthLoading = true);
    try {
      final result = await _curatorRunner(
        task: ModuleCuratorTask.healthReview,
      );
      if (!mounted) return;
      await showModuleCuratorAdviceDialog(
        context,
        title: 'Salute moduli — AI Curator',
        result: result,
      );
    } catch (error) {
      if (!mounted) return;
      await showModuleCuratorErrorDialog(context, error);
    } finally {
      if (mounted) {
        setState(() => _healthLoading = false);
      }
    }
  }

  Future<void> _connect() async {
    final controller = TextEditingController(text: _clientId ?? '');
    final clientId = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Connetti Module Library'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Inserisci il Client ID pubblico della GitHub App dedicata alla '
              'Module Library. Nessun client secret o private key deve essere '
              'inserito nell\'app.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'GitHub App Client ID',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.of(dialogContext).pop(value);
            },
            child: const Text('Continua'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (clientId == null || !mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _configStore.saveClientId(clientId);
      final authorization = await _authClient.requestDeviceAuthorization(
        clientId: clientId,
      );
      if (!mounted) return;
      setState(() {
        _clientId = clientId;
        _loading = false;
      });
      await _showDeviceAuthorization(
        clientId: clientId,
        authorization: authorization,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _showDeviceAuthorization({
    required String clientId,
    required WorkshopGitHubDeviceAuthorization authorization,
  }) async {
    DateTime nextPollAt = DateTime.now();
    String status = 'Apri GitHub, inserisci il codice e autorizza la GitHub App.';
    var polling = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> poll() async {
            if (polling) return;
            final now = DateTime.now();
            if (now.isBefore(nextPollAt)) {
              final seconds = nextPollAt.difference(now).inSeconds + 1;
              setDialogState(() {
                status = 'Attendi circa $seconds secondi prima del prossimo controllo.';
              });
              return;
            }
            setDialogState(() => polling = true);
            try {
              final result = await _authClient.pollDeviceAuthorization(
                clientId: clientId,
                deviceCode: authorization.deviceCode,
              );
              switch (result.state) {
                case WorkshopGitHubDevicePollState.authorized:
                  final credential = result.credential;
                  if (credential == null) {
                    throw const FormatException(
                      'GitHub non ha restituito una credenziale valida.',
                    );
                  }
                  await _credentialStore.save(credential);
                  if (!mounted) return;
                  setState(() {
                    _connected = true;
                    _error = null;
                  });
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                  await _refresh();
                  return;
                case WorkshopGitHubDevicePollState.authorizationPending:
                  nextPollAt = DateTime.now().add(authorization.interval);
                  setDialogState(() {
                    status = 'Autorizzazione non ancora completata su GitHub.';
                  });
                case WorkshopGitHubDevicePollState.slowDown:
                  final wait = result.minimumInterval ?? authorization.interval;
                  nextPollAt = DateTime.now().add(wait);
                  setDialogState(() {
                    status = 'GitHub chiede di attendere prima del prossimo controllo.';
                  });
                case WorkshopGitHubDevicePollState.expired:
                  setDialogState(() {
                    status = 'Codice scaduto. Chiudi e avvia una nuova connessione.';
                  });
                case WorkshopGitHubDevicePollState.accessDenied:
                  setDialogState(() {
                    status = 'Autorizzazione negata su GitHub.';
                  });
              }
            } catch (error) {
              setDialogState(() => status = error.toString());
            } finally {
              if (dialogContext.mounted) {
                setDialogState(() => polling = false);
              }
            }
          }

          return AlertDialog(
            title: const Text('Autorizza su GitHub'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Codice dispositivo:'),
                  const SizedBox(height: 6),
                  SelectableText(
                    authorization.userCode,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 14),
                  SelectableText(authorization.verificationUri.toString()),
                  const SizedBox(height: 14),
                  Text(status),
                ],
              ),
            ),
            actions: [
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: authorization.userCode),
                  );
                  if (context.mounted) {
                    setDialogState(() => status = 'Codice copiato negli appunti.');
                  }
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copia codice'),
              ),
              TextButton.icon(
                onPressed: () async {
                  try {
                    if (Platform.isAndroid) {
                      final intent = AndroidIntent(
                        action: 'android.intent.action.VIEW',
                        data: authorization.verificationUri.toString(),
                      );
                      await intent.launch();
                    } else {
                      await Clipboard.setData(
                        ClipboardData(
                          text: authorization.verificationUri.toString(),
                        ),
                      );
                      if (context.mounted) {
                        setDialogState(() {
                          status = 'Link GitHub copiato negli appunti.';
                        });
                      }
                    }
                  } catch (error) {
                    if (context.mounted) {
                      setDialogState(() => status = error.toString());
                    }
                  }
                },
                icon: const Icon(Icons.open_in_browser),
                label: const Text('Apri GitHub'),
              ),
              TextButton(
                onPressed: polling
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: const Text('Annulla'),
              ),
              FilledButton(
                onPressed: polling ? null : () => unawaited(poll()),
                child: polling
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Ho autorizzato'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _disconnect() async {
    await _credentialStore.clear();
    if (!mounted) return;
    setState(() {
      _connected = false;
      _items = const <ModuleCapabilityStatus>[];
      _lastUpdatedAt = null;
      _curatorLoading.clear();
      _healthLoading = false;
      _error = null;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moduli'),
        actions: [
          if (_connected)
            IconButton(
              tooltip: 'Salute moduli — AI Curator',
              onPressed: _healthLoading ? null : () => unawaited(_runHealthReview()),
              icon: _healthLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.health_and_safety_outlined),
            ),
          if (_connected)
            IconButton(
              tooltip: 'Aggiorna',
              onPressed: _loading ? null : () => unawaited(_refresh()),
              icon: const Icon(Icons.refresh),
            ),
          if (!_externalRepository)
            IconButton(
              tooltip: _connected ? 'Disconnetti GitHub' : 'Connetti GitHub',
              onPressed: _loading
                  ? null
                  : () => unawaited(_connected ? _disconnect() : _connect()),
              icon: Icon(_connected ? Icons.link_off : Icons.link),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_connected
              ? _ConnectionView(
                  clientId: _clientId,
                  error: _error,
                  onConnect: _connect,
                )
              : _error != null
                  ? _ErrorView(
                      error: _error!,
                      onRetry: _refresh,
                      onReconnect: _externalRepository ? null : _connect,
                    )
                  : _ModuleIndexView(
                      items: _items,
                      updatedAt: _lastUpdatedAt,
                      onRefresh: _refresh,
                      curatorLoading: _curatorLoading,
                      onCurator: _runCuratorForCapability,
                    ),
    );
  }
}

class _ModuleIndexView extends StatelessWidget {
  const _ModuleIndexView({
    required this.items,
    required this.updatedAt,
    required this.onRefresh,
    required this.curatorLoading,
    required this.onCurator,
  });

  final List<ModuleCapabilityStatus> items;
  final DateTime? updatedAt;
  final Future<void> Function() onRefresh;
  final Set<String> curatorLoading;
  final Future<void> Function(ModuleCapabilityStatus) onCurator;

  @override
  Widget build(BuildContext context) {
    final sorted = List<ModuleCapabilityStatus>.of(items)
      ..sort((left, right) {
        final leftEmpty = left.presentCount == 0;
        final rightEmpty = right.presentCount == 0;
        if (leftEmpty != rightEmpty) return leftEmpty ? 1 : -1;
        final byPresence = right.presentCount.compareTo(left.presentCount);
        if (byPresence != 0) return byPresence;
        return left.title.toLowerCase().compareTo(right.title.toLowerCase());
      });

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: sorted.length + 1,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index == 0) return _LastUpdatedBanner(updatedAt: updatedAt);
          final status = sorted[index - 1];
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            title: Text('${status.title} (${status.progressLabel})'),
            subtitle: Text('Funzione: ${_briefFunction(status)}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _ModuleCapabilityDetailPage(
                    status: status,
                    curatorLoading: curatorLoading.contains(status.capabilityId),
                    onCurator: () => unawaited(onCurator(status)),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _briefFunction(ModuleCapabilityStatus status) {
    const descriptions = <String, String>{
      'ai.acceleration_backend': 'Accelera l’inferenza AI su CPU/GPU e backend disponibili.',
      'ai.local_inference': 'Esegue i modelli AI direttamente sul dispositivo.',
      'ai.model_storage': 'Gestisce archiviazione e disponibilità dei modelli AI.',
      'diagnostics.logging': 'Raccoglie log e diagnostica del sistema.',
      'network.http': 'Gestisce richieste e comunicazioni HTTP.',
      'storage.local_db': 'Gestisce dati persistenti nel database locale.',
      'storage.secrets': 'Conserva credenziali e segreti in modo protetto.',
      'voice.stt': 'Converte la voce in testo.',
      'voice.tts': 'Converte il testo in voce.',
    };
    return descriptions[status.capabilityId] ??
        'Fornisce la capacità ${status.title.toLowerCase()}.';
  }
}

class _ModuleCapabilityDetailPage extends StatelessWidget {
  const _ModuleCapabilityDetailPage({
    required this.status,
    required this.curatorLoading,
    required this.onCurator,
  });

  final ModuleCapabilityStatus status;
  final bool curatorLoading;
  final VoidCallback onCurator;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(status.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _CapabilityCard(
            status: status,
            curatorLoading: curatorLoading,
            onCurator: onCurator,
          ),
        ],
      ),
    );
  }
}

class _ConnectionView extends StatelessWidget {
  const _ConnectionView({
    required this.clientId,
    required this.error,
    required this.onConnect,
  });

  final String? clientId;
  final String? error;
  final Future<void> Function() onConnect;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.inventory_2_outlined, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    'Connetti la Module Library',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'L\'app usa GitHub Device Flow. Nel dispositivo non vengono '
                    'salvati client secret o chiavi private; il token utente '
                    'resta nello storage sicuro del sistema.',
                    textAlign: TextAlign.center,
                  ),
                  if (clientId != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Client ID configurato: $clientId',
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => unawaited(onConnect()),
                    icon: const Icon(Icons.login),
                    label: const Text('Connetti GitHub'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LastUpdatedBanner extends StatelessWidget {
  const _LastUpdatedBanner({required this.updatedAt});

  final DateTime? updatedAt;

  @override
  Widget build(BuildContext context) {
    final updated = updatedAt;
    final label = updated == null
        ? 'Ultimo aggiornamento: non disponibile'
        : 'Ultimo aggiornamento: '
            '${updated.day.toString().padLeft(2, '0')}/'
            '${updated.month.toString().padLeft(2, '0')}/'
            '${updated.year} '
            '${updated.hour.toString().padLeft(2, '0')}:'
            '${updated.minute.toString().padLeft(2, '0')}';
    return Semantics(
      label: label,
      child: Row(
        children: [
          const Icon(Icons.schedule_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({
    required this.status,
    required this.curatorLoading,
    required this.onCurator,
  });

  final ModuleCapabilityStatus status;
  final bool curatorLoading;
  final VoidCallback onCurator;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.primary;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: outline, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              status.title,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              status.capabilityId,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Chip(
                label: Text(status.statusLabel),
              ),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: status.desiredCandidates == 0
                  ? 0
                  : (status.presentCount / status.desiredCandidates)
                      .clamp(0, 1)
                      .toDouble(),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InfoChip(
                  'Certificati',
                  '${status.presentCount}/${status.desiredCandidates}',
                ),
                if (status.research.available)
                  _InfoChip('Candidati', '${status.research.candidateCount}'),
                if (status.research.shortlisted > 0)
                  _InfoChip('Shortlist', '${status.research.shortlisted}'),
                if (status.research.securityReview > 0)
                  _InfoChip(
                    'Security review',
                    '${status.research.securityReview}',
                  ),
                if (status.certifiedDeprecated > 0)
                  _InfoChip('Deprecated', '${status.certifiedDeprecated}'),
                if (status.revoked > 0)
                  _InfoChip('Revocati', '${status.revoked}'),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Target: ${status.targets.join(', ')}',
              style: theme.textTheme.bodySmall,
            ),
            if (!status.research.available) ...[
              const SizedBox(height: 8),
              Text(
                'Stato Researcher non disponibile: i conteggi certificati '
                'restano comunque autoritativi dalla Library.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: curatorLoading ? null : onCurator,
                icon: curatorLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_outlined),
                label: Text(
                  curatorLoading ? 'Analisi in corso…' : 'Consiglio AI',
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Consultivo: non modifica certificazione, stato o conteggi.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Chip(
      label: Text('$label: $value'),
      shape: StadiumBorder(
        side: BorderSide(color: theme.colorScheme.primary, width: 1.5),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.error,
    required this.onRetry,
    this.onReconnect,
  });

  final String error;
  final Future<void> Function() onRetry;
  final Future<void> Function()? onReconnect;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            const Text('Impossibile caricare lo stato dei moduli.'),
            const SizedBox(height: 8),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => unawaited(onRetry()),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Riprova'),
                ),
                if (onReconnect != null)
                  OutlinedButton.icon(
                    onPressed: () => unawaited(onReconnect!()),
                    icon: const Icon(Icons.login),
                    label: const Text('Riconnetti'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
