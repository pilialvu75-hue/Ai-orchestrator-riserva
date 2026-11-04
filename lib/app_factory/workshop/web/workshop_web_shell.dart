import 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_broker.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_self_test.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_language.dart';
import 'package:flutter/material.dart';

enum WorkshopWebCapabilityState {
  available,
  planned,
  unavailable,
}

enum WorkshopWebCapability {
  cantiereShell,
  durableStorage,
  cloudAuto,
  moduleLibrary,
  researcher,
  diagnostics,
  nativeLocalInference,
  nativeProcessExecution,
}

abstract final class WorkshopWebCapabilities {
  static const Map<WorkshopWebCapability, WorkshopWebCapabilityState> current =
      <WorkshopWebCapability, WorkshopWebCapabilityState>{
    WorkshopWebCapability.cantiereShell:
        WorkshopWebCapabilityState.available,
    WorkshopWebCapability.durableStorage:
        WorkshopWebCapabilityState.available,
    WorkshopWebCapability.cloudAuto:
        WorkshopWebCapabilityState.available,
    WorkshopWebCapability.moduleLibrary:
        WorkshopWebCapabilityState.planned,
    WorkshopWebCapability.researcher:
        WorkshopWebCapabilityState.planned,
    WorkshopWebCapability.diagnostics:
        WorkshopWebCapabilityState.planned,
    WorkshopWebCapability.nativeLocalInference:
        WorkshopWebCapabilityState.unavailable,
    WorkshopWebCapability.nativeProcessExecution:
        WorkshopWebCapabilityState.unavailable,
  };

  static WorkshopWebCapabilityState state(WorkshopWebCapability capability) =>
      current[capability] ?? WorkshopWebCapabilityState.unavailable;
}

/// Browser-safe Cantiere shell.
///
/// W3 adds only the pure checkpoint persistence contract. Native runtime,
/// filesystem/process execution, voice, updater, native database and general
/// Assistant composition remain outside the Web compilation graph.
class WorkshopWebShell extends StatelessWidget {
  const WorkshopWebShell({
    super.key,
    required this.checkpointStore,
    required this.cloudHealth,
    this.selfTestClient,
  });

  final Future<WorkshopCheckpointStore> checkpointStore;
  final Future<WorkshopWebCloudBrokerHealth> cloudHealth;
  final WorkshopWebCloudSelfTestClient? selfTestClient;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  'Aivexus',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white54,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  WorkshopWebLanguageScope.tr(context, 'Cantiere Web'),
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Browser startup ready • shared Workshop contract '
                      'stage=${WorkshopStage.requested.name}',
                  style: const TextStyle(
                    color: Colors.white70,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 28),
                const _CapabilityCard(
                  title: 'Cantiere shell',
                  subtitle:
                      'Browser-safe startup with no native or Assistant dependency.',
                  state: WorkshopWebCapabilityState.available,
                ),
                _DurableStorageCard(
                  checkpointStore: checkpointStore,
                ),
                _CloudAutoCard(
                  cloudHealth: cloudHealth,
                  selfTestClient: selfTestClient,
                ),
                const _CapabilityCard(
                  title: 'Module Library + Researcher',
                  subtitle:
                      'Shared contracts remain the target; browser adapter comes later.',
                  state: WorkshopWebCapabilityState.planned,
                ),
                const _CapabilityCard(
                  title: 'Diagnostics',
                  subtitle:
                      'Browser-safe queue/transport is planned; public privacy projection stays shared.',
                  state: WorkshopWebCapabilityState.planned,
                ),
                const _CapabilityCard(
                  title: 'Native local inference',
                  subtitle:
                      'Explicitly unavailable in W1; no llama.cpp/FFI fallback is attempted.',
                  state: WorkshopWebCapabilityState.unavailable,
                ),
                const _CapabilityCard(
                  title: 'Native process execution',
                  subtitle:
                      'Explicitly unavailable in the browser.',
                  state: WorkshopWebCapabilityState.unavailable,
                ),
                const SizedBox(height: 20),
                const Text(
                  'PWA/installable/offline-first browser work is intentionally '
                  'not enabled in this release ring.',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CloudAutoCard extends StatefulWidget {
  const _CloudAutoCard({
    required this.cloudHealth,
    this.selfTestClient,
  });

  final Future<WorkshopWebCloudBrokerHealth> cloudHealth;
  final WorkshopWebCloudSelfTestClient? selfTestClient;

  @override
  State<_CloudAutoCard> createState() => _CloudAutoCardState();
}

class _CloudAutoCardState extends State<_CloudAutoCard> {
  late final Future<WorkshopWebCloudBrokerHealth> _health;
  late final WorkshopWebCloudSelfTestClient _selfTestClient;
  bool _selfTestRunning = false;
  WorkshopWebCloudSelfTestResult? _selfTestResult;

  @override
  void initState() {
    super.initState();
    _health = widget.cloudHealth;
    _selfTestClient = widget.selfTestClient ?? WorkshopWebCloudSelfTestClient();
  }

  Future<void> _runSelfTest() async {
    if (_selfTestRunning) return;
    setState(() {
      _selfTestRunning = true;
      _selfTestResult = null;
    });
    try {
      final result = await _selfTestClient.run();
      if (mounted) setState(() => _selfTestResult = result);
    } finally {
      if (mounted) setState(() => _selfTestRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FutureBuilder<WorkshopWebCloudBrokerHealth>(
          future: _health,
          builder: (context, snapshot) {
            final health = snapshot.data;
            if (snapshot.hasError || (health != null && !health.isReady)) {
              return _CapabilityCard(
                title: 'Cloud / AUTO execution',
                subtitle: health?.errorCode == null
                    ? 'Server-side broker is reachable but one or more Cantiere capabilities are not configured.'
                    : 'Server-side broker unavailable: ${health!.errorCode}.',
                state: WorkshopWebCapabilityState.unavailable,
              );
            }
            if (health == null) {
              return const _CapabilityCard(
                title: 'Cloud / AUTO execution',
                subtitle:
                    'Checking the server-side capability broker. No provider secret is stored in the browser.',
                state: WorkshopWebCapabilityState.planned,
              );
            }
            return const _CapabilityCard(
              title: 'Cloud / AUTO execution',
              subtitle:
                  'Server-side AUTO routing ready for Orchestrator, Architect, Engineer and Reviewer.',
              state: WorkshopWebCapabilityState.available,
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: OutlinedButton.icon(
            onPressed: _selfTestRunning ? null : _runSelfTest,
            icon: _selfTestRunning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.science_outlined),
            label: Text(
              WorkshopWebLanguageScope.tr(context, _selfTestRunning ? 'Self-Test in corso…' : 'Esegui Self-Test Cloud'),
            ),
          ),
        ),
        if (_selfTestResult case final result?)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        result.passed
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        color: result.passed ? Colors.greenAccent : Colors.amber,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        WorkshopWebLanguageScope.tr(context,
                          result.errorCode == 'self_test_not_configured'
                              ? 'Self-Test non configurato'
                              : result.passed
                                  ? 'Cloud Self-Test Passed'
                                  : 'Cloud Self-Test Not Passed'),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(WorkshopWebLanguageScope.tr(context, result.detail)),
                  const SizedBox(height: 8),
                  Text(
                    'HTTP: ${result.statusCode?.toString() ?? '—'}'
                    ' · Tempo: ${result.elapsed.inMilliseconds} ms',
                  ),
                  if (result.provider != null)
                    Text('Provider (endpoint): ${result.provider}'),
                  if (result.configuredModel != null)
                    Text('Modello configurato: ${result.configuredModel}'),
                  if (result.reportedModel != null)
                    Text('Modello dichiarato dal provider: ${result.reportedModel}'),
                  if (result.routeId != null)
                    Text('Rotta: ${result.routeId}'),
                  if (result.tokensGenerated != null)
                    Text('Token generati: ${result.tokensGenerated}'),
                  if (result.passed)
                    const Text('Testo generato: AIVEXUS_WEB_SELF_TEST_OK'),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _DurableStorageCard extends StatefulWidget {
  const _DurableStorageCard({
    required this.checkpointStore,
  });

  final Future<WorkshopCheckpointStore> checkpointStore;

  @override
  State<_DurableStorageCard> createState() => _DurableStorageCardState();
}

class _DurableStorageCardState extends State<_DurableStorageCard> {
  late final Future<List<WorkshopBackgroundCheckpoint>> _checkpointProbe;

  @override
  void initState() {
    super.initState();
    _checkpointProbe = widget.checkpointStore.then((store) => store.loadAll());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<WorkshopBackgroundCheckpoint>>(
      future: _checkpointProbe,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _CapabilityCard(
            title: 'Durable browser storage',
            subtitle:
                'Unavailable: persistent Workshop checkpoints could not be opened or read.',
            state: WorkshopWebCapabilityState.unavailable,
          );
        }
        final checkpoints = snapshot.data;
        if (checkpoints == null) {
          return const _CapabilityCard(
            title: 'Durable browser storage',
            subtitle:
                'Opening the existing Workshop checkpoint persistence contract.',
            state: WorkshopWebCapabilityState.planned,
          );
        }
        return _CapabilityCard(
          title: 'Durable browser storage',
          subtitle:
              'Existing WorkshopCheckpointStore active • '
              '${checkpoints.length} saved checkpoint(s).',
          state: WorkshopWebCapabilityState.available,
        );
      },
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({
    required this.title,
    required this.subtitle,
    required this.state,
  });

  final String title;
  final String subtitle;
  final WorkshopWebCapabilityState state;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (state) {
      WorkshopWebCapabilityState.available =>
        (Icons.check_circle_outline, 'Available'),
      WorkshopWebCapabilityState.planned =>
        (Icons.schedule_outlined, 'Planned'),
      WorkshopWebCapabilityState.unavailable =>
        (Icons.block_outlined, 'Unavailable'),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    WorkshopWebLanguageScope.tr(context, title),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    WorkshopWebLanguageScope.tr(context, subtitle),
                    style: const TextStyle(
                      color: Colors.white60,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              WorkshopWebLanguageScope.tr(context, label),
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white60,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
