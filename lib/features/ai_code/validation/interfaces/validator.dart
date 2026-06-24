import 'package:ai_orchestrator/features/ai_code/workspace/models/file_diff.dart';
import 'package:ai_orchestrator/features/ai_code/validation/models/validation_result.dart';

/// Contratto astratto per l'implementazione di qualsiasi motore di controllo linting o sintattico.
abstract class Validator {
  Future<ValidationResult> validate(List<FileDiff> diffs);
}
