import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

/// Materializza una [WorkshopChangeProposal] nel VirtualWorkspace.
///
/// Questo componente rappresenta il ponte tra:
///
///   proposta LLM
///        ↓
///   WorkshopChangeProposal
///        ↓
///   VirtualWorkspace
///
/// e NON tra proposta e repository reale.
///
/// Responsabilità:
/// - verificare che la proposta appartenga alla sessione corretta;
/// - trasferire aggiunte/modifiche/cancellazioni nel VirtualWorkspace;
/// - lasciare disponibile il diff per review e validation.
///
/// NON:
/// - approva le modifiche;
/// - applica le modifiche al repository reale;
/// - esegue commit;
/// - esegue push;
/// - chiama direttamente un LLM;
/// - gestisce la UI.
///
/// Il passaggio successivo rimane quindi esplicitamente:
///
///   proposal
///      ↓
///   virtual workspace
///      ↓
///   review
///      ↓
///   validation
///      ↓
///   approveApply()
///      ↓
///   apply()
final class WorkshopWorkspaceProposalApplier {
  const WorkshopWorkspaceProposalApplier();

  /// Applica virtualmente una proposta alla [session].
  ///
  /// Le modifiche vengono scritte esclusivamente nel
  /// [WorkspaceSession.workspace].
  ///
  /// Il repository reale NON viene modificato.
  ///
  /// Restituisce la sessione stessa per permettere una composizione
  /// semplice nella pipeline del Cantiere.
  WorkspaceSession applyProposal({
    required WorkspaceSession session,
    required WorkshopChangeProposal proposal,
  }) {
    final requestId = session.context.request.id;

    if (proposal.requestId != requestId) {
      throw StateError(
        'Workshop change proposal belongs to request '
        '"${proposal.requestId}", but the active workspace session '
        'belongs to "$requestId".',
      );
    }

    if (!session.workspace.isInitialized) {
      throw StateError(
        'The workspace session must be initialized before applying '
        'a change proposal.',
      );
    }

    final status = session.status;

    if (status != WorkspaceSessionStatus.ready &&
        status != WorkspaceSessionStatus.working) {
      throw StateError(
        'Change proposals can only be materialized while the workspace '
        'session is ready or working. Current status: ${status.name}.',
      );
    }

    if (proposal.isEmpty) {
      return session;
    }

    session.beginImplementation();

    for (final change in proposal.changes) {
      final path = change.path.trim();

      if (path.isEmpty) {
        throw ArgumentError(
          'A workspace change cannot have an empty path.',
        );
      }

      if (change.isAddition || change.isModification) {
        final content = change.afterContent;

        if (content == null) {
          throw StateError(
            'Change "$path" is ${change.type.name} but does not '
            'contain afterContent.',
          );
        }

        session.workspace.write(
          path: path,
          content: content,
        );
        continue;
      }

      if (change.isDeletion) {
        session.workspace.delete(path);
        continue;
      }

      throw UnsupportedError(
        'Unsupported workspace change type for "$path": ${change.type}.',
      );
    }

    return session;
  }

  /// Restituisce il diff risultante dalla proposta senza applicare
  /// ulteriori modifiche.
  ///
  /// Questo metodo è intenzionalmente separato da [applyProposal]:
  /// la UI può utilizzare il diff per mostrare all'utente cosa
  /// il Cantiere intende fare prima della review.
  ///
  /// Nota: il diff viene letto dalla sessione e rappresenta quindi
  /// l'intero stato corrente del VirtualWorkspace, non solamente
  /// l'ultima proposta.
  dynamic buildCurrentDiff(WorkspaceSession session) {
    return session.diff;
  }
}
