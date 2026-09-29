import 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
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
        WorkshopWebCapabilityState.planned,
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
  });

  final Future<WorkshopCheckpointStore> checkpointStore;

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
                  'AI-Orchestrator',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white54,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Cantiere Web',
                  style: TextStyle(
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
                const _CapabilityCard(
                  title: 'Cloud / AUTO execution',
                  subtitle:
                      'Planned for the Web execution ring; no provider secret is bundled here.',
                  state: WorkshopWebCapabilityState.planned,
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
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
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
              label,
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
