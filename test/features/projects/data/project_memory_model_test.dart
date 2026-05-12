import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/projects/data/models/project_memory_model.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';

void main() {
  const tModel = ProjectMemoryModel(
    id: 'model-id-1',
    masterGoal: 'Test goal',
    currentContext: 'Test context',
    lastCodeSnippet: 'void main() {}',
    timestamp: 1700000000000,
  );

  final tMap = {
    AppConstants.colId: 'model-id-1',
    AppConstants.colMasterGoal: 'Test goal',
    AppConstants.colCurrentContext: 'Test context',
    AppConstants.colLastCodeSnippet: 'void main() {}',
    AppConstants.colTimestamp: 1700000000000,
  };

  group('ProjectMemoryModel', () {
    test('fromMap creates a valid model', () {
      final model = ProjectMemoryModel.fromMap(tMap);

      expect(model.id, tMap[AppConstants.colId]);
      expect(model.masterGoal, tMap[AppConstants.colMasterGoal]);
      expect(model.currentContext, tMap[AppConstants.colCurrentContext]);
      expect(model.lastCodeSnippet, tMap[AppConstants.colLastCodeSnippet]);
      expect(model.timestamp, tMap[AppConstants.colTimestamp]);
    });

    test('toMap produces the correct map', () {
      final map = tModel.toMap();

      expect(map[AppConstants.colId], tModel.id);
      expect(map[AppConstants.colMasterGoal], tModel.masterGoal);
      expect(map[AppConstants.colCurrentContext], tModel.currentContext);
      expect(map[AppConstants.colLastCodeSnippet], tModel.lastCodeSnippet);
      expect(map[AppConstants.colTimestamp], tModel.timestamp);
    });

    test('fromMap → toMap is a round-trip', () {
      final model = ProjectMemoryModel.fromMap(tMap);
      expect(model.toMap(), tMap);
    });

    test('copyWith overrides specified fields', () {
      final copy = tModel.copyWith(masterGoal: 'New goal');
      expect(copy.masterGoal, 'New goal');
      expect(copy.id, tModel.id);
    });

    test('fromMap handles missing optional fields gracefully', () {
      // Forniamo solo i campi obbligatori per testare la robustezza del modello
      final sparseMap = {
        AppConstants.colId: 'sparse-id',
        AppConstants.colTimestamp: 0,
      };
      
      final model = ProjectMemoryModel.fromMap(sparseMap);
      
      expect(model.id, 'sparse-id');
      // Verifichiamo che i campi mancanti vengano inizializzati con valori di default (stringhe vuote)
      expect(model.masterGoal, '');
      expect(model.currentContext, '');
      expect(model.lastCodeSnippet, '');
    });
  });
}
