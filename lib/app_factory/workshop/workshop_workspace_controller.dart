import '../workspace/virtual_workspace.dart';
import 'workshop_contract.dart';

/// Controls the Workshop's interaction with its workspace.
///
/// This controller is deliberately kept between [WorkshopEngine] and the
/// concrete workspace implementation.
///
/// The Workshop must be able to work locally and offline. Therefore this
/// controller does NOT require GitHub, a network connection, or an LLM.
///
/// Remote repository synchronisation can be added later as an independent
/// adapter without changing the Workshop pipeline.
///
/// Responsibilities:
/// - open/prepare a workspace for a Workshop request;
/// - expose the workspace to the construction pipeline;
/// - keep workspace concerns outside [WorkshopEngine];
/// - preserve the separation between the Assistant and the Workshop;
/// - provide a safe boundary for future file/diff operations.
///
/// IMPORTANT:
/// This first implementation does not automatically write files.
/// Actual mutations remain explicitly controlled by the workspace layer.
final class WorkshopWorkspaceController {
  WorkshopWorkspaceController({
    VirtualWorkspace? workspace,
  }) : _workspace = workspace;

  VirtualWorkspace? _workspace;

  /// Current workspace used by the Workshop.
  VirtualWorkspace? get workspace => _workspace;

  /// Whether a workspace is currently attached.
  bool get hasWorkspace => _workspace != null;

  /// Attaches an existing workspace to the Workshop.
  ///
  /// The workspace may be entirely local, which means the Workshop remains
  /// usable when the device has no Internet connection.
  void attach(VirtualWorkspace workspace) {
    _workspace = workspace;
  }

  /// Detaches the current workspace.
  ///
  /// This does not delete files or alter the underlying project.
  void detach() {
    _workspace = null;
  }

  /// Prepares the workspace boundary for a Workshop request.
  ///
  /// At this stage this method intentionally performs no destructive action.
  /// It validates that the Workshop has a workspace available when the
  /// request explicitly identifies a project path.
  WorkshopWorkspacePreparation prepare(
    WorkshopRequest request,
  ) {
    final currentWorkspace = _workspace;

    if (currentWorkspace == null) {
      return WorkshopWorkspacePreparation(
        requestId: request.id,
        ready: false,
        message:
            'No local workspace is attached to the Workshop.',
        warnings: const <String>[
          'workspace_not_attached',
        ],
      );
    }

    return WorkshopWorkspacePreparation(
      requestId: request.id,
      ready: true,
      message:
          'Local workspace is ready for Workshop operations.',
    );
  }

  /// Releases the controller's reference to the workspace.
  ///
  /// The workspace itself is not deleted or modified.
  void dispose() {
    _workspace = null;
  }
}

/// Result of preparing the Workshop workspace boundary.
final class WorkshopWorkspacePreparation {
  const WorkshopWorkspacePreparation({
    required this.requestId,
    required this.ready,
    required this.message,
    this.warnings = const <String>[],
  });

  final String requestId;
  final bool ready;
  final String message;
  final List<String> warnings;

  bool get hasWarnings => warnings.isNotEmpty;
}
