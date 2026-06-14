import '../models/code_patch.dart';
import '../models/workspace_apply_result.dart';

/// Sandbox in memoria (VFS) che isola il codice reale dell'applicazione 
/// dalle manipolazioni transitorie indotte dall'AI.
class VirtualWorkspace {
  final Map<String, String> _sandbox = {};

  /// Inizializza l'ambiente di lavoro con lo stato reale dei file del file system.
  void initializeSandbox(Map<String, String> initialFiles) {
    _sandbox.clear();
    _sandbox.addAll(initialFiles);
  }

  /// Restituisce una vista immutabile dello stato corrente del VFS.
  Map<String, String> get currentState => Map.unmodifiable(_sandbox);

  /// Recupera il contenuto di un singolo file.
  String? getFileContent(String filePath) => _sandbox[filePath];

  /// Applica una patch modificando lo stato interno della sandbox.
  WorkspaceApplyResult applyPatch(CodePatch patch) {
    try {
      if (patch.filePath.isEmpty) {
        return const WorkspaceApplyResult.failure('Il percorso del file non può essere vuoto.');
      }
      _sandbox[patch.filePath] = patch.updatedContent;
      return const WorkspaceApplyResult.success();
    } catch (e) {
      return WorkspaceApplyResult.failure('Errore di scrittura nel file system virtuale: $e');
    }
  }

  /// Cattura lo stato grezzo dei dati (Meccanismo di snapshot nativo per la Fase 1).
  Map<String, String> captureRawState() => Map.from(_sandbox);

  /// Ripristina lo stato grezzo cancellando le mutazioni non convalidate.
  void restoreRawState(Map<String, String> state) {
    _sandbox.clear();
    _sandbox.addAll(state);
  }
}
