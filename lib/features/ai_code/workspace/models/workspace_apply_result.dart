import 'package:meta/meta.dart';

/// Specifica l'esito della scrittura a basso livello all'interno del Virtual File System.
/// Consente all'Orchestrator di intercettare fallimenti prima della validazione.
@immutable
class WorkspaceApplyResult {
  final bool success;
  final String? errorMessage;

  const WorkspaceApplyResult.success() : success = true, errorMessage = null;
  const WorkspaceApplyResult.failure(this.errorMessage) : success = false;
}
