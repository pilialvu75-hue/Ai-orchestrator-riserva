import 'package:http/http.dart' as http;

import 'durable/workshop_durable_final_build_controller.dart';
import 'durable/workshop_durable_github_actions_coordinator.dart';
import 'durable/workshop_durable_orchestrator.dart';
import 'workshop_bounded_http_client.dart';
import 'workshop_build_lab.dart';
import 'workshop_durable_github_build_provider.dart';
import 'workshop_github_user_token_provider.dart';
import 'workshop_persistent_checkpoint_store.dart';
import 'workshop_private_github_build_provider.dart';
import 'workshop_private_github_durable_artifact_finalizer.dart';
import 'workshop_private_github_durable_gateway.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/features/module_library/data/module_library_github_config.dart';

/// Production composition for the restart-safe private GitHub final-build path.
///
/// It deliberately reuses the canonical Preferences-backed Workshop checkpoint
/// store. No second database or execution identity is introduced.
abstract final class WorkshopDurablePrivateGitHubBuildFactory {
  static const WorkshopPrivateGitHubBuildConfiguration configuration =
      WorkshopPrivateGitHubBuildConfiguration(
    repository: 'pilialvu75-hue/AI-Orchestrator-Module-Library',
    workflowFile: 'build-cantiere-android.yml',
    baseBranch: 'main',
    requirePrivateRepository: true,
  );

  static WorkshopBuildProvider create({
    required PreferencesService preferences,
    Duration requestTimeout = const Duration(seconds: 20),
    Duration foregroundPollInterval = const Duration(seconds: 5),
  }) {
    final tokenProvider = WorkshopGitHubUserTokenProvider(
      clientIdProvider: ModuleLibraryGitHubConfigStore().loadClientId,
    );

    WorkshopBoundedHttpClient boundedClient() => WorkshopBoundedHttpClient(
          inner: http.Client(),
          timeout: requestTimeout,
        );

    final checkpointStore = PersistentWorkshopCheckpointStore(
      preferences: preferences,
    );
    final orchestrator = WorkshopDurableOrchestrator(
      store: WorkshopCheckpointDurableOrchestrationStore(
        checkpointStore: checkpointStore,
      ),
    );
    final gateway = WorkshopPrivateGitHubDurableGateway(
      configuration: configuration,
      accessTokenProvider: tokenProvider.call,
      client: boundedClient(),
    );
    final githubCoordinator = WorkshopDurableGitHubActionsCoordinator(
      orchestrator: orchestrator,
      gateway: gateway,
    );
    final finalizer = WorkshopPrivateGitHubDurableArtifactFinalizer(
      configuration: configuration,
      accessTokenProvider: tokenProvider.call,
      client: boundedClient(),
    );
    final finalBuildController = WorkshopDurableFinalBuildController(
      orchestrator: orchestrator,
      githubCoordinator: githubCoordinator,
      finalizeArtifact: finalizer.finalize,
    );

    // The historical provider is retained only as the toolchain/auth probe for
    // BuildLab selection. Its polling build() is no longer used by this default
    // production composition.
    final inspectionDelegate = WorkshopPrivateGitHubBuildProvider(
      configuration: configuration,
      accessTokenProvider: tokenProvider.call,
      client: boundedClient(),
    );

    return WorkshopDurableGitHubBuildProvider(
      advance: finalBuildController.advance,
      toolchainDelegate: inspectionDelegate,
      pollInterval: foregroundPollInterval,
    );
  }
}
