import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/ai_code/workspace/models/code_patch.dart';
import 'package:ai_orchestrator/features/ai_code/workspace/services/virtual_workspace.dart';
import 'package:ai_orchestrator/features/ai_code/workspace/services/workspace_diff_builder.dart';
import 'package:ai_orchestrator/features/ai_code/validation/services/basic_text_validator.dart';
import 'package:ai_orchestrator/features/ai_code/orchestrator/services/code_orchestrator_impl.dart';

void main() {
  late VirtualWorkspace workspace;
  late WorkspaceDiffBuilder diffBuilder;
  late BasicTextValidator validator;
  late CodeOrchestratorImpl orchestrator;

  setUp(() {
    workspace = VirtualWorkspace();
    diffBuilder = WorkspaceDiffBuilder();
    validator = BasicTextValidator();
    
    // Inizializziamo l'orchestratore iniettando le dipendenze della Fase 1
    orchestrator = CodeOrchestratorImpl(
      workspace: workspace,
      diffBuilder: diffBuilder,
      validators: [validator],
    );
  });

  group('CodeOrchestrator - Validazione Transazionale Fase 1', () {
    
    test('Scenario A: Applicazione di una patch valida (SUCCESS)', () async {
      // Predisponiamo uno stato iniziale nella sandbox
      workspace.initializeSandbox({'lib/main.dart': 'void main() {}'});

      final result = await orchestrator.processPatches([
        const CodePatch(
          filePath: 'lib/main.dart',
          updatedContent: 'void main() { print("Hello AI"); }',
        )
      ]);

      expect(result.success, isTrue);
      expect(result.diffs.length, 1);
      expect(result.diffs.first.hasChanges, isTrue);
      expect(workspace.getFileContent('lib/main.dart'), 'void main() { print("Hello AI"); }');
    });

    test('Scenario B: File vuoto accidentalmente (ROLLBACK)', () async {
      final oldContent = 'void main() { print("Keep me"); }';
      workspace.initializeSandbox({'lib/main.dart': oldContent});

      final result = await orchestrator.processPatches([
        const CodePatch(
          filePath: 'lib/main.dart',
          updatedContent: '   ', // Patch che svuota il file (invalida)
        )
      ]);

      // L'orchestratore deve rifiutare la modifica e attivare il Rollback
      expect(result.success, isFalse);
      expect(result.validationReport?.isValid, isFalse);
      // Lo stato del file system virtuale deve essere tornato a quello precedente
      expect(workspace.getFileContent('lib/main.dart'), oldContent);
    });

    test('Scenario C: Patch identica senza variazioni (NO DIFF)', () async {
      workspace.initializeSandbox({'lib/utils.dart': 'class Utils {}'});

      final result = await orchestrator.processPatches([
        const CodePatch(
          filePath: 'lib/utils.dart',
          updatedContent: 'class Utils {}', // Nessun cambiamento reale
        )
      ]);

      // Deve fallire perché non c'è una variazione strutturale (ottimizzazione dei commit)
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Nessuna variazione di codice rilevata'));
    });

    test('Scenario D: Modifiche concorrenti su più file (MULTI FILE SUCCESS)', () async {
      workspace.initializeSandbox({
        'lib/model.dart': 'class Model {}',
        'lib/view.dart': 'class View {}',
      });

      final result = await orchestrator.processPatches([
        const CodePatch(filePath: 'lib/model.dart', updatedContent: 'class Model { final int id = 1; }'),
        const CodePatch(filePath: 'lib/view.dart', updatedContent: 'class View { void render() {} }'),
      ]);

      expect(result.success, isTrue);
      expect(result.diffs.length, 2);
      expect(workspace.getFileContent('lib/model.dart'), contains('id = 1'));
      expect(workspace.getFileContent('lib/view.dart'), contains('render()'));
    });
  });
}
