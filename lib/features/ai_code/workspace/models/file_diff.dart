import 'package:meta/meta.dart';

/// Descrive la variazione atomica tra lo stato originario e quello aggiornato di un file.
@immutable
class FileDiff {
  final String filePath;
  final String? originalContent;
  final String? updatedContent;

  const FileDiff({
    required this.filePath,
    this.originalContent,
    this.updatedContent,
  });

  bool get isNewFile => originalContent == null;
  bool get isDeleted => updatedContent == null;
  bool get hasChanges => originalContent != updatedContent;
}
