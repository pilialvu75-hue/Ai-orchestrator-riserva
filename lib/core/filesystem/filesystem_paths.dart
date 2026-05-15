import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class FilesystemPaths {
  FilesystemPaths._();

  static Future<String> getApplicationDocumentsPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  static Future<String> getModelsDirectoryPath() async {
    final docs = await getApplicationDocumentsPath();
    return p.join(docs, 'models');
  }

  static Future<String> getCachePath() async {
    try {
      final dir = await getApplicationCacheDirectory();
      return dir.path;
    } catch (_) {
      final dir = await getTemporaryDirectory();
      return dir.path;
    }
  }

  static Future<String> getRuntimeStoragePath() async {
    final docs = await getApplicationDocumentsPath();
    return p.join(docs, 'runtime');
  }

  static Future<String> getDownloadsPath() async {
    final docs = await getApplicationDocumentsPath();
    return p.join(docs, 'downloads');
  }

  static String joinPaths(String base, List<String> segments) {
    return p.joinAll([base, ...segments]);
  }

  static bool isValidPath(String path) {
    if (path.isEmpty) return false;
    if (path.contains('\x00')) return false;

    // Reject any path segment equal to '..' after normalisation.
    // p.normalize handles both forward- and back-slash separators.
    final normalized = p.normalize(path);
    final parts = p.split(normalized);
    if (parts.contains('..')) return false;

    // Guard against raw traversal sequences before normalization on any OS.
    if (path.contains('../') ||
        path.contains('..\\') ||
        path.endsWith('/..') ||
        path.endsWith('\\..') ||
        path == '..') {
      return false;
    }

    return true;
  }
}
