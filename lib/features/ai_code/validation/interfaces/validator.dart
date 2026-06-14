import '../../workspace/models/file_diff.dart';
import '../models/validation_result.dart';

/// Contratto astratto per l'implementazione di qualsiasi motore di controllo linting o sintattico.
abstract class Validator {
  Future<ValidationResult> validate(List<FileDiff> diffs);
}
