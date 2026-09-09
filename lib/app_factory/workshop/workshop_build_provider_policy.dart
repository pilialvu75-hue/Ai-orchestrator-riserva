import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';

/// Ordering policy for Cantiere build providers.
///
/// Automatic builds prefer remote execution to save device time, battery and
/// thermal budget when connectivity-backed providers are available. Local
/// providers remain the deterministic fallback and explicit local/offline
/// requests are still enforced by [WorkshopBuildLab] mode filtering.
///
/// This policy only orders existing providers. It does not create runtimes,
/// credentials, downloaders, workspaces or Assistant dependencies.
abstract final class WorkshopBuildProviderPolicy {
  static List<WorkshopBuildProvider> remotePreferred(
    Iterable<WorkshopBuildProvider> providers,
  ) {
    final source = List<WorkshopBuildProvider>.of(providers);

    final ordered = <WorkshopBuildProvider>[
      ...source.where(
        (provider) =>
            provider.executionMode == WorkshopBuildExecutionMode.remote,
      ),
      ...source.where(
        (provider) =>
            provider.executionMode == WorkshopBuildExecutionMode.offlineLocal,
      ),
      ...source.where(
        (provider) =>
            provider.executionMode == WorkshopBuildExecutionMode.local,
      ),
      ...source.where(
        (provider) =>
            provider.executionMode == WorkshopBuildExecutionMode.automatic,
      ),
    ];

    return List<WorkshopBuildProvider>.unmodifiable(ordered);
  }
}
