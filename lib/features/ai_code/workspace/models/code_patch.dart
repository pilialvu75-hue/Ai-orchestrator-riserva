import 'package:meta/meta.dart';

/// Rappresenta la singola intenzione di modifica di un file inviata dall'agente AI.
/// È l'oggetto di input primario dell'intera architettura.
@immutable
class CodePatch {
  final String filePath;
  final String updatedContent;

  const CodePatch({
    required this.filePath,
    required this.updatedContent,
  });
}
