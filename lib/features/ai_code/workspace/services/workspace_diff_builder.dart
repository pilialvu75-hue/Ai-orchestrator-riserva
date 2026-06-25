import 'package:ai_orchestrator/features/ai_code/workspace/models/file_diff.dart';

/// Calcola i delta strutturali staccando la generazione del diff logico 
/// dallo stato mutabile del workspace.
class WorkspaceDiffBuilder {
  /// Confronta due istantanee del VFS ed emette la lista dei delta calcolati.
  List<FileDiff> buildDiffs(Map<String, String> oldState, Map<String, String> newState) {
    final List<FileDiff> diffs = [];
    final allKeys = {...oldState.keys, ...newState.keys};

    for (final key in allKeys) {
      final oldContent = oldState[key];
      final newContent = newState[key];

      if (oldContent != newContent) {
        diffs.add(FileDiff(
          filePath: key,
          originalContent: oldContent,
          updatedContent: newContent,
        ));
      }
    }
    return diffs;
  }
}
