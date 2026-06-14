import '../../workspace/models/file_diff.dart';
import '../interfaces/validator.dart';
import '../models/validation_result.dart';

/// Validatore euristico veloce anti-rumore operante su stringhe grezze.
/// Ripulito dai controlli sulle parentesi graffe per azzerare i falsi positivi.
class BasicTextValidator implements Validator {
  @override
  Future<ValidationResult> validate(List<FileDiff> diffs) async {
    final List<String> errors = [];

    for (final diff in diffs) {
      final content = diff.updatedContent;
      if (content == null) continue; // Salta file in eliminazione logica

      // 1. Controllo file vuoto accidentalmente: evita file corrotti o troncati a zero
      if (content.trim().isEmpty) {
        errors.add('Il file [${diff.filePath}] risulta vuoto dopo l\'applicazione delle patch.');
      }

      // 2. Controllo anti-inquinamento marker Git conflittuali residui
      if (content.contains('<<<<<<<') || content.contains('=======') || content.contains('>>>>>>>')) {
        errors.add('Rilevati conflitti di unione Git insoluti nel corpo del file [${diff.filePath}].');
      }
    }

    return ValidationResult(
      isValid: errors.isEmpty,
      errors: errors,
    );
  }
}
