import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal_decoder.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_workspace_proposal_applier.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

/// Bridges an Engineer response into the existing VirtualWorkspace pipeline.
///
/// This boundary deliberately performs only three operations:
/// 1. decode the structured Engineer response into a WorkshopChangeProposal;
/// 2. materialize that proposal inside the active WorkspaceSession;
/// 3. move the session to review once the virtual changes are staged.
///
/// It never approves or applies changes to the real repository. Reviewer,
/// validation and explicit approval remain mandatory later stages.
final class WorkshopProposalWorkspaceStager {
  const WorkshopProposalWorkspaceStager({
    WorkshopWorkspaceProposalApplier applier =
        const WorkshopWorkspaceProposalApplier(),
  }) : _applier = applier;

  final WorkshopWorkspaceProposalApplier _applier;

  WorkshopChangeProposal stage({
    required WorkspaceSession session,
    required String responseText,
  }) {
    final proposal = WorkshopChangeProposalDecoder.decode(
      requestId: session.context.request.id,
      responseText: responseText,
      existingPaths: session.workspace.paths.toSet(),
    );

    _validateTaskScope(
      session: session,
      proposal: proposal,
    );
    _validateDartNativeImports(proposal);

    final alreadyHasStagedChanges = session.hasChanges;
    if (proposal.isNotEmpty &&
        !alreadyHasStagedChanges &&
        !_materializesWorkspaceChange(
          session: session,
          proposal: proposal,
        )) {
      throw const FormatException(
        'Workshop proposal produced no staged workspace changes.',
      );
    }

    _applier.applyProposal(
      session: session,
      proposal: proposal,
    );

    if (proposal.isNotEmpty) {
      session.beginReview();
    }

    return proposal;
  }

  // Kotlin/Java class names are not Dart import URIs, even for Flutter
  // applications targeting Android. Catch this proven physical +3140 failure
  // before staging so the existing bounded Engineer structural retry can
  // attempt a correct Flutter widget implementation. This is deliberately
  // narrower than a compiler/analyzer: legitimate Dart package/relative
  // imports and supported native platform channels stay permitted.
  static final RegExp _dartImportPattern = RegExp(
    r'''(?m)^\s*import\s+['"]([^'"]+)['"]''',
  );
  static final RegExp _jvmClassUriPattern = RegExp(
    r'^(?:com|org|android|androidx)\.[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)+
    required WorkspaceSession session,
    required WorkshopChangeProposal proposal,
  }) {
    for (final change in proposal.changes) {
      final path = change.path.trim();
      if (change.isDeletion) {
        if (session.workspace.contains(path)) {
          return true;
        }
        continue;
      }

      if (change.isAddition || change.isModification) {
        final next = change.afterContent;
        if (next != null && session.workspace.read(path) != next) {
          return true;
        }
      }
    }
    return false;
  }

  static void _validateTaskScope({
    required WorkspaceSession session,
    required WorkshopChangeProposal proposal,
  }) {
    final request = session.context.request;
    final targetFiles = request.targetFiles
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();

    if (targetFiles.isNotEmpty) {
      for (final change in proposal.changes) {
        final path = change.path.trim();
        if (!targetFiles.contains(path)) {
          throw FormatException(
            'Workshop proposal path "$path" is outside the current '
            'task targetFiles.',
          );
        }
      }
    }

    if (request.operation == WorkshopOperation.create &&
        targetFiles.contains('lib/main.dart') &&
        !session.workspace.contains('lib/main.dart')) {
      final materializesEntryPoint = proposal.changes.any(
        (change) =>
            change.path.trim() == 'lib/main.dart' && !change.isDeletion,
      );
      if (!materializesEntryPoint) {
        throw const FormatException(
          'Workshop create proposal must materialize required target '
          '"lib/main.dart".',
        );
      }
    }
  }
}
,
  );

  static void _validateDartNativeImports(WorkshopChangeProposal proposal) {
    for (final change in proposal.changes) {
      if (change.isDeletion || !change.path.toLowerCase().endsWith('.dart')) {
        continue;
      }
      final content = change.afterContent;
      if (content == null) continue;
      for (final match in _dartImportPattern.allMatches(content)) {
        final uri = match.group(1);
        if (uri != null &&
            !uri.endsWith('.dart') &&
            _jvmClassUriPattern.hasMatch(uri)) {
          throw FormatException(
            'Workshop Dart source imports an Android/JVM class directly. '
            'Implement UI in Flutter/Dart, or provide a declared platform '
            'channel with matching native implementation.',
            change.path,
          );
        }
      }
    }
  }

  static bool _materializesWorkspaceChange({
    required WorkspaceSession session,
    required WorkshopChangeProposal proposal,
  }) {
    for (final change in proposal.changes) {
      final path = change.path.trim();
      if (change.isDeletion) {
        if (session.workspace.contains(path)) {
          return true;
        }
        continue;
      }

      if (change.isAddition || change.isModification) {
        final next = change.afterContent;
        if (next != null && session.workspace.read(path) != next) {
          return true;
        }
      }
    }
    return false;
  }

  static void _validateTaskScope({
    required WorkspaceSession session,
    required WorkshopChangeProposal proposal,
  }) {
    final request = session.context.request;
    final targetFiles = request.targetFiles
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();

    if (targetFiles.isNotEmpty) {
      for (final change in proposal.changes) {
        final path = change.path.trim();
        if (!targetFiles.contains(path)) {
          throw FormatException(
            'Workshop proposal path "$path" is outside the current '
            'task targetFiles.',
          );
        }
      }
    }

    if (request.operation == WorkshopOperation.create &&
        targetFiles.contains('lib/main.dart') &&
        !session.workspace.contains('lib/main.dart')) {
      final materializesEntryPoint = proposal.changes.any(
        (change) =>
            change.path.trim() == 'lib/main.dart' && !change.isDeletion,
      );
      if (!materializesEntryPoint) {
        throw const FormatException(
          'Workshop create proposal must materialize required target '
          '"lib/main.dart".',
        );
      }
    }
  }
}
