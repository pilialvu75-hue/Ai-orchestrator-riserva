import 'package:ai_orchestrator/app_factory/workspace/virtual_workspace.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';

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
/// This controller does not automatically write files.
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

  /// Whether the attached workspace has already been initialized.
  bool get isWorkspaceInitialized =>
      _workspace?.isInitialized ?? false;

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
  /// This method intentionally performs no destructive action and does not
  /// initialize the workspace automatically. Initialization belongs to the
  /// workspace lifecycle and must be explicitly controlled by the caller.
  ///
  /// The preparation result therefore answers one simple question:
  /// "Can this Workshop request proceed because a workspace boundary exists?"
  ///
  /// If the request identifies a project path while no workspace is
  /// attached, the result remains blocked and exposes the reason through
  /// [WorkshopWorkspacePreparation.warnings].
  WorkshopWorkspacePreparation prepare(
    WorkshopRequest request,
  ) {
    final currentWorkspace = _workspace;

    if (currentWorkspace == null) {
      final warnings = <String>[
        'workspace_not_attached',
      ];

      if (request.projectPath != null &&
          request.projectPath!.trim().isNotEmpty) {
        warnings.add('project_path_requires_workspace');
      }

      return WorkshopWorkspacePreparation(
        requestId: request.id,
        ready: false,
        message:
            'No local workspace is attached to the Workshop.',
        warnings: List<String>.unmodifiable(warnings),
      );
    }

    final warnings = <String>[];

    if (!currentWorkspace.isInitialized) {
      warnings.add('workspace_not_initialized');
    }

    final projectPath = request.projectPath?.trim();

    if (projectPath != null && projectPath.isNotEmpty) {
      warnings.add(
        'project_path_validation_deferred_to_workspace',
      );
    }

    return WorkshopWorkspacePreparation(
      requestId: request.id,
      ready: true,
      message:
          currentWorkspace.isInitialized
              ? 'Local workspace is ready for Workshop operations.'
              : 'Local workspace is attached and must be initialized before file operations.',
      warnings: List<String>.unmodifiable(warnings),
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

  /// Indicates whether the workspace can safely be used for operations
  /// that require an initialized virtual workspace.
  bool get canOperate => ready && !warnings.contains(
        'workspace_not_initialized',
      );
}
