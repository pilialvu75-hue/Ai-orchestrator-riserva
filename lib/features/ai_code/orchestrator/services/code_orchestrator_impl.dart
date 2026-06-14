import '../../workspace/models/code_patch.dart';
import '../../workspace/models/file_diff.dart';
import '../../workspace/services/virtual_workspace.dart';
import '../../workspace/services/workspace_diff_builder.dart';
import '../../validation/interfaces/validator.dart';
import '../../validation/models/validation_result.dart';

/// Oggetto di ritorno transitorio per isolare l'esito dell'orchestrazione nella Fase 1.
class OrchestrationResultPhase1 {
  final bool success;
  final List<FileDiff> diffs;
  final String? errorMessage;
  final ValidationResult? validationReport;

  const OrchestrationResultPhase1({
    required this.success,
    required this.diffs,
    this.errorMessage,
    this.validationReport,
  });
}

/// Gestore transazionale e coordinatore multicomponente adibito ad applicare
/// le patch e a decretare l'eventuale rollback automatico in caso di fallimento.
class CodeOrchestratorImpl {
  final VirtualWorkspace _workspace;
  final WorkspaceDiffBuilder _diffBuilder;
  final List<Validator> _validators;

  CodeOrchestratorImpl({
    required VirtualWorkspace workspace,
    required WorkspaceDiffBuilder diffBuilder,
    required List<Validator> validators,
  })  : _workspace = workspace,
        _diffBuilder = diffBuilder,
        _validators = validators;

  /// Processa un blocco di patch in regime di isolamento atomico locale.
  Future<OrchestrationResultPhase1> processPatches(List<CodePatch> patches) async {
    // 1. Snapshot dello stato antecedente alla transazione
    final oldState = _workspace.captureRawState();

    try {
      // 2. Applicazione sequenziale ordinata delle patch nel VFS
      for (final patch in patches) {
        final result = _workspace.applyPatch(patch);
        if (!result.success) {
          _workspace.restoreRawState(oldState); // Ripristino immediato
          return OrchestrationResultPhase1(
            success: false,
            diffs: const [],
            errorMessage: 'Applicazione interrotta sul file [${patch.filePath}]: ${result.errorMessage}',
          );
        }
      }

      // 3. Calcolo dei delta logici strutturali
      final newState = _workspace.currentState;
      final diffs = _diffBuilder.buildDiffs(oldState, newState);

      // Guardrail: Intercettazione pacchetti vuoti o identici
      if (diffs.isEmpty) {
        return const OrchestrationResultPhase1(
          success: false,
          diffs: [],
          errorMessage: 'Nessuna variazione di codice rilevata rispetto allo stato attuale.',
        );
      }

      // 4. Catena di validazione euristica disaccoppiata
      for (final validator in _validators) {
        final report = await validator.validate(diffs);
        if (!report.isValid) {
          // STRATEGIA ROLLBACK: Pulizia della sandbox a fronte di anomalie euristiche
          _workspace.restoreRawState(oldState);
          return OrchestrationResultPhase1(
            success: false,
            diffs: diffs,
            errorMessage: 'Integrità violata: ${report.errors.join(" | ")}',
            validationReport: report,
          );
        }
      }

      // Transazione locale superata con successo
      return OrchestrationResultPhase1(
        success: true,
        diffs: diffs,
      );
    } catch (e) {
      // Fallback totale di sicurezza in caso di crash imprevisti del runtime
      _workspace.restoreRawState(oldState);
      return OrchestrationResultPhase1(
        success: false,
        diffs: const [],
        errorMessage: 'Eccezione critica interna intercettata nell\'Orchestrator: $e',
      );
    }
  }
}
