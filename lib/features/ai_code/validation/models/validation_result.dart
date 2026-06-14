import 'package:meta/meta.dart';

/// Contiene il verdetto della catena di controllo ed elenca le anomalie riscontrate.
@immutable
class ValidationResult {
  final bool isValid;
  final List<String> errors;

  const ValidationResult({
    required this.isValid,
    required this.errors,
  });

  int get errorCount => errors.length;
}
